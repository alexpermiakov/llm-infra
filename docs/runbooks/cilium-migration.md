# Runbook: VPC CNI → Cilium Migration (Istio Removal)

**Relates to:** [ADR-001](../adr/001-vpc-cni-to-cilium.md)
**Target version:** Cilium 1.17.x
**Estimated duration:** 3–4 weeks (dev → staging → prod)

## Overview

Three sequential phases. Each is independently validatable and rollbackable on the live cluster
— no new cluster required.

```
Phase 1 ── Cilium chaining mode (Hubble + policy, VPC CNI still owns IPAM)
Phase 2 ── CNI replacement: VPC CNI → Cilium ENI/native (rolling node drain)
Phase 3 ── Istio removal: CiliumNetworkPolicy replaces AuthorizationPolicy;
           WireGuard node encryption closes the transit-confidentiality gap
Phase 4 ── SPIRE-backed Cilium Mutual Auth for per-workload mTLS
```

Phase 1 is zero-restart. Phases 2 and 3 require node drains (PDB-respecting, no expected
customer impact).

See ADR-001 for rationale, alternatives considered, and architecture details.

## Pre-flight (every phase)

```bash
kubectl get pdb -A                                  # all healthy
kubectl argo rollouts list rollouts -A              # no active canary
kubectl get nodeclaims -A && kubectl get nodepools -A
kubectl get nodes                                   # all Ready
```

Before Phase 2 specifically:

```bash
# Cilium chaining mode is healthy
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.cni-chaining-mode}'  # → aws-cni
kubectl get pods -n kube-system -l k8s-app=aws-node                                  # vpc-cni still up
```

---

## Phase 1: Install Cilium in chaining mode

**Goal:** Cilium runs alongside VPC CNI for policy + Hubble. VPC CNI still owns IPAM.

### 1.1 Apply Cilium module

`infra/modules/cilium/main.tf` defines the Helm release. Phase 1 values use
`cni.chainingMode=aws-cni`, `cni.exclusive=false`, `ipam.mode=cluster-pool`,
`kubeProxyReplacement=false`, Hubble enabled with relay/UI, NodePort enabled for Gateway API.

```bash
terraform apply -target=module.cilium
```

### 1.2 Gateway API CRDs

CRDs are installed by the same module from a vendored manifest
(`infra/modules/cilium/files/gateway-api-standard-install.yaml`) read via `file()` so
`for_each` keys are statically known. To upgrade: replace the YAML, bump
`gateway_api_version` in `locals`, apply.

```bash
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
```

### 1.3 Validate

```bash
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get pods -n kube-system -l io.cilium/app=operator
cilium hubble status
cilium hubble observe --type l7 --protocol http   # confirm L7 visibility
```

**Rollback:** `helm uninstall cilium -n kube-system`. VPC CNI unaffected.

---

## Phase 2: CNI Migration — VPC CNI → Cilium ENI

**Goal:** Cilium becomes sole CNI and IPAM. kube-proxy replaced by eBPF. Enables transparent
mTLS and L7 policy.

> **Highest-risk phase.** VPC CNI and Cilium ENI cannot coexist on a node — every workload
> node is replaced. Run dev → staging → prod with ≥3 days between environments.

### Critical ordering

1. **Stage cilium-nodes pool first**, then cordon, then atomic Terraform apply, then drain.
2. **Disable the `default` Karpenter pool before draining** — otherwise it satisfies evicted
   pods on nodes booted with broken IPAM.
3. **vpc-cni removal + Cilium ENI upgrade = one apply** (2.4 + 2.5). Between them the cluster
   has no IPAM for new pods.
4. **vpc-cni first, then Cilium values** within that apply, so new Karpenter nodes never see
   the `aws-node` DS.
5. **kube-proxy last** (2.7) — old nodes still need its iptables rules during drain.

Cordoning is safe: it sets `spec.unschedulable=true` only. It does not evict pods and does not
trigger Karpenter (no Pending pods → no provisioning, no consolidation either).

### 2.2 Stage Karpenter cilium-nodes pool

Add `EC2NodeClass` (`cilium-nodeclass`) and `NodePool` (`cilium-nodes`, label `cni=cilium`)
to the EKS module. Mirror the existing `default` pool's requirements (arch, instance category,
size, capacity-type) so Karpenter does not launch a c7gd.16xlarge for a 100m pod. CPU/memory
limits should match the `default` pool budget — **do not double it**. Use
`disruption.consolidationPolicy: WhenEmptyOrUnderutilized` (v1 CRD rejects `WhenUnderutilized`).

```bash
terraform apply -target=kubectl_manifest.karpenter_cilium_node_class \
                -target=kubectl_manifest.karpenter_cilium_node_pool
```

### 2.2b Disable the `default` pool

In `kubectl_manifest.karpenter_node_pool` (the `default` pool):

```hcl
limits     = { cpu = "0", memory = "0" }
disruption = { budgets = [{ nodes = "0" }] }
```

`limits=0` blocks new provisioning; existing nodes are untouched. `budgets.nodes=0` stops
Karpenter consolidation/drift from racing your manual drain.

```bash
terraform apply -target=kubectl_manifest.karpenter_node_pool
```

### 2.3 Cordon all non-Cilium nodes

```bash
kubectl cordon -l 'cni!=cilium'
kubectl get nodes | grep SchedulingDisabled
```

Cordoning bootstrap is fine — Karpenter keeps running there; we are not draining bootstrap.

### 2.4 + 2.5 Atomic apply: remove vpc-cni and switch Cilium to ENI

Stage both changes on one branch and apply together:

- `infra/modules/eks/main.tf`: remove the `vpc-cni` block from `addons`. Leave `kube-proxy`
  for now.
- `infra/modules/cilium/variables.tf`: add `variable "cluster_endpoint"`.
- `infra/entry/main.tf`: `module "cilium" { ... cluster_endpoint = module.eks.cluster_endpoint }`.
- `infra/modules/cilium/main.tf`: replace Phase 1 values block with the ENI config.

Phase 2 Helm value deltas (everything else from Phase 1 unchanged):

| Setting                                                      | Phase 2                                                                   |
| ------------------------------------------------------------ | ------------------------------------------------------------------------- |
| `cni.chainingMode`                                           | `"none"`                                                                  |
| `cni.exclusive`                                              | `true`                                                                    |
| `ipam.mode`                                                  | `"eni"`                                                                   |
| `eni.enabled`                                                | `true` (also `updateEC2AdapterLimit: true`)                               |
| `routingMode`                                                | `"native"` (keep — required by ENI)                                       |
| `ipv4NativeRoutingCIDR`                                      | `var.vpc_cidr` (keep — required by native routing)                        |
| `egressMasqueradeInterfaces`                                 | `"ens+"` (AL2023; without this IRSA → STS times out)                      |
| `kubeProxyReplacement`                                       | `true`                                                                    |
| `k8sServiceHost`                                             | `trimprefix(var.cluster_endpoint, "https://")` (hostname only, no scheme) |
| `k8sServicePort`                                             | `"443"`                                                                   |
| `autoDirectNodeRoutes`, `socketLB.enabled`, `bpf.masquerade` | **Remove** (chaining-mode artifacts)                                      |

Do **not** enable Cilium Mutual Auth / SPIRE here — it deadlocks during the cutover. Defer to
Phase 3. Use WireGuard node encryption (`encryption.type=wireguard`, `nodeEncryption=true`)
if transit confidentiality is needed before Phase 3.

```bash
terraform apply -target=module.eks -target=module.cilium
```

**Why existing pods survive:** kubelet calls the CNI binary only at pod ADD/DEL. Between
those, the kernel maintains veth + routes, not the CNI DS. Removing `aws-node` removes ipamd
(breaks new-pod IP allocation on old nodes — hence the cordon) but does not touch live kernel
state.

> **Orphan DaemonSet — `aws-node` is left behind by the addon removal.** EKS does not GC the
> underlying workload. Delete it manually:
>
> ```bash
> kubectl -n kube-system delete daemonset aws-node
> ```

> **`cni.exclusive=true` conflicts with istio-cni-node.** Cilium reconciles `/etc/cni/net.d/`
> and deletes any non-owned conflist. istio-cni-node fights back, ends up CrashLoopBackOff.
> Since the Istio dataplane is already disabled (`istio.io/dataplane-mode=none`), nothing
> depends on istio-cni — bring forward Phase 3 cleanup:
>
> ```bash
> kubectl -n istio-system delete daemonset istio-cni-node
> ```

> **Stale cilium-config?** The init container reads the ConfigMap once at start.
> `kubectl -n kube-system rollout restart ds/cilium` to pick up corrections.

#### Optional: gate cilium-agent restart with `OnDelete` (recommended for prod)

With default `RollingUpdate`, the Helm upgrade restarts cilium-agent on every node — including
cordoned-but-still-serving ones — which can briefly disrupt long-lived TCP flows. To defer the
per-node restart until drain time:

```bash
kubectl -n kube-system patch ds cilium -p '{"spec":{"updateStrategy":{"type":"OnDelete"}}}'
# ...run apply, drain (2.6)...
kubectl -n kube-system patch ds cilium -p '{"spec":{"updateStrategy":{"type":"RollingUpdate"}}}'
```

Dev/staging: in-place restart is acceptable.

### 2.6 Rolling drain

Karpenter provisions cilium-nodes lazily as pods become Pending. Drain only Karpenter-owned
non-Cilium nodes; **never drain bootstrap** (Karpenter runs there — see below).

```bash
for node in $(kubectl get nodes -l 'cni!=cilium,karpenter.sh/nodepool' -o name); do
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=10m
  sleep 60
done

# Watch in another terminal
watch kubectl get nodes -L cni,karpenter.sh/nodepool
```

> **PDB deadlock on a Deployment with one healthy replica.** If `minAvailable: 1` and the
> other replica is pre-existing CrashLoopBackOff, drain hangs. Delete the unhealthy pod first
> — it reschedules onto a Cilium node, satisfying PDB for the original eviction. We hit this
> with `order-service`.

Confirm critical workloads moved:

```bash
kubectl get pods -n argocd -o wide
kubectl get pods -n monitoring -o wide
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
```

Karpenter does not auto-terminate cordoned nodes — delete the Node objects to release the EC2
instances:

```bash
for node in $(kubectl get nodes -l 'cni!=cilium,karpenter.sh/nodepool' \
    --field-selector spec.unschedulable=true -o name); do
  kubectl delete "$node"
done
```

**Bootstrap MNG is permanent — leave it running.** Karpenter has hard
`nodeAffinity: karpenter.sh/nodepool DoesNotExist`, so it cannot run on cilium-nodes. The
bootstrap node keeps its old vpc-cni-allocated IPs (kernel state survives addon removal); it
flips to Cilium ENI lazily on the next AMI/k8s version bump, or you can force it with
`aws eks update-nodegroup-version --force-update-enabled`. Not required for Phase 2
completion. See `memories/repo/cilium-karpenter-pool-ownership.md`.

### 2.7 Remove kube-proxy

All workload nodes are now Cilium with `kubeProxyReplacement=true`. Remove the `kube-proxy`
addon block from `infra/modules/eks/main.tf`:

```bash
terraform apply -target=module.eks
```

Same orphan-DS issue as `aws-node`:

```bash
kubectl -n kube-system delete daemonset kube-proxy
kubectl get pods -A | grep kube-proxy   # → empty
```

(All Istio repo touchpoints — module, chart templates, SG rules — are removed in Phase 3 below.)

### 2.8 Validate

```bash
kubectl get pods -n kube-system -l k8s-app=cilium    # all Ready
kubectl get pods -A -o wide                          # IPs from VPC CIDR
cilium connectivity test                             # full L3/L4/L7 sweep
kubectl get pods -A | grep aws-node                  # → empty
```

**Rollback:** Reintroduce vpc-cni addon and provision VPC-CNI nodes back, then drain Cilium
nodes. Worst case: Velero restore + DNS failover to DR region. Hard. **Always succeed in
staging before touching prod.**

---

## Phase 3: Remove Istio

After Phase 2, Cilium owns CNI. WireGuard node encryption (enabled in
`infra/modules/cilium/main.tf`) provides transit confidentiality; SPIRE-backed
workload mTLS lands in Phase 4. Istio is redundant. The repo-side cleanup (module,
chart templates, ApplicationSet labels, SG rules, Kyverno sidecar policies, Argo
Rollouts metric queries) is already merged. The remaining work is in the live
cluster.

### 3.1 Disable sidecar injection (any namespaces still labeled)

```bash
kubectl get ns -l istio.io/rev=default -o name | xargs -I{} kubectl label {} istio.io/rev-
# Rolling-restart so existing pods drop their sidecars
kubectl get rollouts -A -o name | xargs -I{} kubectl argo rollouts restart {}
```

### 3.2 Apply the new chart

ArgoCD will sync the updated `standard-service` chart, which now emits a
`CiliumNetworkPolicy` (replacing the old `AuthorizationPolicy`) and no longer renders a
`PeerAuthentication`. Confirm:

```bash
kubectl get cnp -A
kubectl get authorizationpolicies -A 2>&1 | head    # CRD may already be gone post-uninstall
```

### 3.3 Confirm WireGuard node encryption is active

`infra/modules/cilium/main.tf` enables `encryption.type=wireguard` with
`nodeEncryption=true`. Verify in the live cluster:

```bash
kubectl -n kube-system exec ds/cilium -- cilium status | grep -i encryption
# Expect: Encryption: Wireguard [NodeEncryption: Enabled, ...]

kubectl -n kube-system exec ds/cilium -- cilium encrypt status
# Expect: Encryption: Wireguard
#         Interface: cilium_wg0  Number of peers: <N-1>
```

Per-workload mTLS (`authentication.mode=required`) is configured in Phase 4 once
SPIRE is installed.

### 3.4 Uninstall Istio from the cluster

```bash
helm uninstall istiod istio-cni -n istio-system 2>/dev/null || true
helm uninstall istio-base -n istio-system 2>/dev/null || true
kubectl delete namespace istio-system
```

If Terraform state still references the old module (pre-merge clusters):

```bash
terraform state list | grep module.istio | xargs -L1 terraform state rm -lock=false
```

### 3.5 Validate

```bash
kubectl get ns istio-system 2>&1 || echo "gone"
# Confirm no Envoy sidecars remain
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.containers[*]}{.name} {end}{"\n"}{end}' | grep istio-proxy && echo FAIL || echo OK
cilium hubble observe --type l7 --verdict FORWARDED | head
```

---

## Phase 4: SPIRE-backed Cilium Mutual Authentication

**Goal:** Per-workload mTLS via SPIFFE identities issued by SPIRE. Restores the
logical-access guarantee that Istio's STRICT `PeerAuthentication` provided, while
WireGuard continues to encrypt the transport.

> **Do not run Phase 4 concurrent with any other rolling change** — no AMI
> bumps, no Karpenter pool drift, no Cilium upgrade. The deadlock window opens
> whenever cilium-agent and the SPIRE agent are both restarting and waiting on
> each other for identity / network respectively. A quiet cluster avoids it.

### The deadlock, precisely

```
cilium-agent restart on node N
   → enforces auth.mode=required on local endpoints
   → SPIRE agent pod on N restarts (e.g. drift) and needs an IP
   → CNI ADD is gated on SPIRE identity (auth required)
   → SPIRE can't get an IP → cilium-agent can't reach SPIRE → loop
```

Mitigations encoded in the steps below:

1. SPIRE installed and verified **before** mutual auth is enabled on Cilium.
2. SPIRE agent DS uses host-network + `CriticalAddonsOnly` tolerations so it
   does not depend on CNI for its own IP.
3. Cilium `authentication.mutual.spire.enabled=true` flipped on a quiet cluster
   with the agent DS on `OnDelete` strategy.

### 4.1 Install SPIRE

Use the upstream `spire` Helm chart (or Cilium's bundled SPIRE values — pick one,
not both). Required values:

```yaml
spire-agent:
  hostNetwork: true # bypass CNI for its own pod IP
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - operator: Exists # land on bootstrap during apply
  nodeAttestor:
    k8sPsat:
      enabled: true # PSAT works on EKS without IID setup

spire-server:
  controllerManager:
    enabled: true # auto-registers workload entries
    identities:
      clusterSPIFFEIDs:
        default:
          spiffeIDTemplate: spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}
```

Validate before touching Cilium:

```bash
kubectl -n spire get pods                                       # all Ready
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry show \
  | head -20                                                    # entries exist
```

### 4.2 Switch cilium-agent DS to OnDelete

```bash
kubectl -n kube-system patch ds cilium \
  -p '{"spec":{"updateStrategy":{"type":"OnDelete"}}}'
```

This decouples the Helm value flip (next step) from the agent restarts.

### 4.3 Enable Cilium Mutual Auth

Add to `infra/modules/cilium/main.tf` Helm values:

```hcl
authentication = {
  mutual = {
    spire = {
      enabled        = true
      trustDomain    = "cluster.local"
      serverAddress  = "spire-server.spire.svc:8081"
    }
  }
}
```

```bash
terraform apply -target=module.cilium
```

ConfigMap updates; running agents do not restart (OnDelete).

### 4.4 Per-node rolling restart

```bash
for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system delete "$pod"
  # Wait for the replacement to be Ready before moving on
  kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --timeout=120s
  sleep 30
done
```

Watch for SPIRE identity issuance in another terminal:

```bash
kubectl -n spire logs -f spire-server-0 | grep -i 'agent attested\|workload'
```

### 4.5 Apply cluster-wide mTLS enforcement

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata: { name: mtls-require }
spec:
  endpointSelector: {}
  ingress:
    - authentication: { mode: required } # SPIRE-issued mTLS
      fromEndpoints: [{}]
```

```bash
kubectl apply -f cluster-mtls.yaml
cilium hubble observe --type policy-verdict --verdict DENIED | head
# DROP_REASON_AUTH_REQUIRED on any unauth flow during propagation is expected;
# should drain to zero within ~60s.
```

### 4.6 Restore RollingUpdate strategy

```bash
kubectl -n kube-system patch ds cilium \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate"}}}'
```

### 4.7 Validate

```bash
cilium connectivity test --test mutualauth
kubectl -n kube-system exec ds/cilium -- cilium status | grep -i 'mutual\|spire'
```

**Rollback:** Remove the `CiliumClusterwideNetworkPolicy`, set
`authentication.mutual.spire.enabled=false`, `terraform apply`, rolling-restart
agents. WireGuard transport encryption stays on.

---

## Greenfield bootstrap (Cilium-only, no VPC CNI)

A fresh EKS cluster with no CNI cannot bring up its first node — kubelet
won't go Ready without a CNI binary on disk. Since `vpc-cni` was removed in
Phase 2, every new ephemeral PR cluster would fail the bootstrap NG with
`NodeCreationFailure: Unhealthy nodes` if Cilium were installed in the
default order (after node groups).

### The dependency puzzle

Three layers, each blocked by the next without explicit ordering:

```
┌─ Layer 1: Control plane ──────────────────────────────────────┐
│  module.eks → EKS API server only. No nodes, no addons.       │
└────────────────────────────┬──────────────────────────────────┘
                             │
┌─ Layer 2: First node + CNI ┴──────────────────────────────────┐
│  module.cilium  → Helm-applies DaemonSet manifest (wait=false │
│                   because no nodes exist to schedule on yet). │
│  aws_eks_node_group.bootstrap → launches one t3.medium with   │
│                   taint CriticalAddonsOnly=true:NO_SCHEDULE.  │
│                   Kubelet starts → Cilium DS pod schedules    │
│                   (host-network, tolerates everything) →      │
│                   writes /etc/cni/net.d/ → node goes Ready.   │
└────────────────────────────┬──────────────────────────────────┘
                             │
┌─ Layer 3: Pod-based stuff ─┴──────────────────────────────────┐
│  4× aws_eks_addon (coredns, pod-identity, metrics-server,     │
│                    ebs-csi). Pinned versions in locals.       │
│  helm_release.aws_load_balancer_controller (Karpenter, etc.   │
│                    via other modules).                        │
│  Everything here MUST tolerate CriticalAddonsOnly so it can   │
│  land on the bootstrap node, AND depend_on the bootstrap NG.  │
└───────────────────────────────────────────────────────────────┘
```

### Repo structure that implements it

1. **Control plane only.** `module.eks` (`infra/modules/eks/main.tf`):
   `eks_managed_node_groups = {}` and `addons = {}`. The module just creates
   the EKS control plane and IRSA roles. Every node and every addon lives
   outside the module so we control ordering explicitly.

2. **Cilium first.** `module.cilium` (`infra/modules/cilium/`) runs Helm
   install with `wait = false` and `depends_on = [module.eks]`. The chart
   manifests are applied to the API server immediately; no pods can schedule
   yet (no nodes). Three knobs make this safe at greenfield time:
   - `wait = false` — don't block waiting for DS pods that can't schedule.
   - `operator.tolerations` includes `CriticalAddonsOnly` and a catch-all
     `{operator: Exists}` so the operator pod can land on the bootstrap node.
   - `enable_service_monitors = false` (default) — skips rendering the three
     `ServiceMonitor` objects (Hubble metrics, agent prometheus, operator
     prometheus). The CRD lives in kube-prometheus-stack which installs much
     later. Re-apply with `true` after monitoring is up; second-apply diff
     is just three small SM objects.
   - `replace = true` and `cleanup_on_fail = true` — CI self-heal. If a
     previous attempt left the release in `failed` state, the next install
     purges it instead of erroring `cannot re-use a name that is still in
use`.

3. **Bootstrap node group.** `aws_eks_node_group.bootstrap` in
   `infra/entry/main.tf` (NOT inside `module.eks` — see "Why moved out"
   below). Single t3.medium ON_DEMAND, label
   `node.kubernetes.io/purpose=bootstrap`, taint
   `CriticalAddonsOnly=true:NO_SCHEDULE`. `depends_on = [module.cilium]`
   so the chart manifest is in place before kubelet starts. As soon as
   kubelet comes up, the Cilium DS pod schedules (host-network), writes
   `/etc/cni/net.d/`, and the node registers Ready.

4. **Layer-3 stuff.** All of these live at top level in `infra/entry/main.tf`
   with `depends_on = [aws_eks_node_group.bootstrap]`:
   - `aws_eks_addon.coredns`, `.eks_pod_identity_agent`, `.metrics_server`,
     `.aws_ebs_csi_driver`. Versions pinned via `local.addon_versions`.
     `resolve_conflicts_on_create/update = "OVERWRITE"` so they don't fight
     pre-existing manifests if anything is re-applied.
   - `helm_release.aws_load_balancer_controller`. Values include
     `tolerations: [{key: CriticalAddonsOnly, operator: Exists}]` so its
     pods land on the bootstrap node, and `webhookFailurePolicy: "Ignore"`
     so its mutating webhook can never deadlock the cluster (see "Webhook
     deadlock" below). Same `replace + cleanup_on_fail` self-heal pair.

### Apply order Terraform produces

```
1.  module.eks                          (control plane)
2.  module.cilium                       (Helm manifests applied; no pods yet)
3.  aws_eks_node_group.bootstrap        (first node joins → Cilium DS Ready
                                         → node Ready → CoreDNS unblocks)
4.  aws_eks_addon.* (×4)                (addons go ACTIVE)
5.  helm_release.aws_load_balancer_controller
6.  module.argocd / module.monitoring / module.external_secrets / etc.
7.  Karpenter provisions regular nodes; user workloads land there.
                                         The bootstrap NG keeps running for
                                         the lifetime of the cluster (its
                                         taint keeps non-system pods off).
```

### Why the bootstrap NG and addons had to move out of `module.eks`

When the bootstrap NG lived inside `module.eks` and `module.cilium` had
`depends_on = [module.eks]`, Terraform resolved a cycle: the NG inside the
module needed Cilium's CNI binary present (Layer 2 needs Layer 3), but
Cilium needed the module to finish (Layer 3 needs Layer 2). Pulling the NG
to the top level lets us put `depends_on = [module.cilium]` directly on the
NG resource, breaking the cycle.

Same logic for addons: `aws_eks_addon` waits for the addon to reach
`ACTIVE`, which requires its pods to be Running, which requires a node. If
addons live inside `module.eks` they implicitly run before any node group at
top level, and Terraform hangs on the addon's wait. Moving them to top
level with `depends_on = [aws_eks_node_group.bootstrap]` makes the
dependency explicit and correct.

### Webhook deadlock (one-time gotcha)

The AWS Load Balancer Controller installs a `MutatingWebhookConfiguration`
that intercepts every `Service` create cluster-wide. Default
`failurePolicy: Fail` means: if the controller pods are unreachable, every
Service create is rejected — including the Services Cilium needs to install
(`hubble-peer`, etc.). On first apply with broken networking this produces
a permanent deadlock:

```
Cilium install → API server calls ALB webhook → no endpoints → reject
→ Cilium failed → no CNI → no pods → ALB controller can't start
→ no endpoints → loop forever
```

Setting `webhookFailurePolicy = "Ignore"` in the ALB controller chart values
breaks the cycle: when the webhook is unreachable the API server allows the
Service through unmutated, which is harmless for internal ClusterIP Services
that aren't ALB-bound anyway. See `memories/repo/alb-webhook-deadlock.md`
for manual recovery if you ever hit it.

### Second apply: turn ServiceMonitors back on

Once `module.monitoring` (kube-prometheus-stack) has run and the
`monitoring.coreos.com/v1` CRD exists, set on the `module "cilium"` block
in `infra/entry/main.tf`:

```hcl
enable_service_monitors = true
```

Re-apply. Terraform's diff is three new `ServiceMonitor` objects in the
`monitoring` namespace; the prometheus-operator picks them up on its next
reconcile and Cilium metrics start flowing. No restart of cilium-agent.

### Migrating an existing cluster to this structure

For clusters that pre-date this restructure, the bootstrap node group's
state address changes. Run `terraform state mv` BEFORE `terraform apply` —
without it, Terraform would plan a destroy + recreate of the bootstrap NG,
which would evict every kube-system pod.

```bash
# Per cluster (run from infra/entry with the right backend config):
terraform state mv \
  'module.eks.module.eks.module.eks_managed_node_group["bootstrap"].aws_eks_node_group.this[0]' \
  'aws_eks_node_group.bootstrap'

# The bootstrap NG's IAM role was created by the eks-managed-node-group
# submodule; the new aws_iam_role.bootstrap_node has a different name. The
# old role is orphaned and can be deleted manually after the apply succeeds:
#   aws iam list-attached-role-policies --role-name <old-role>
#   aws iam detach-role-policy ...
#   aws iam delete-role --role-name <old-role>
# A future plan will also show drift on the launch template; accept the
# replacement (the new LT attaches the shared node SG identically).
```

After the state mv, `terraform plan` should show:

- No change to the bootstrap NG resource itself.
- A new `aws_iam_role.bootstrap_node` + 4 policy attachments + 1 launch
  template (replacing the auto-generated ones from the eks submodule).
- All addons gain `before_compute = true` (idempotent on the AWS side).

---

## Downtime Assessment

| Event                                     | Duration                                     | Customer Impact                                                                                    |
| ----------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Phase 1: Cilium install (chaining)        | ~2 min Helm rollout                          | None                                                                                               |
| Phase 2: per-node drain                   | 30–120 s per node                            | None if PDBs hold and replicas ≥ 2                                                                 |
| Phase 2: services with `minReplicas: 1`   | Up to readiness probe                        | Brief (seconds) per service                                                                        |
| Phase 3: rolling restart                  | Per Argo Rollout                             | None                                                                                               |
| Phase 3: WireGuard enable (agent restart) | ~5 s per node with OnDelete + manual stagger | None on host-network; brief reset of in-flight pod-to-pod TCP across the encrypted boundary        |
| Phase 4: SPIRE rollout + mTLS enforce     | ~30 s per node + ~60 s policy propagation    | Brief AUTH_REQUIRED denies until SPIRE entries propagate; mitigated by enforcing cluster-wide last |

Audit `minReplicas: 1` services before Phase 2; either scale up temporarily or accept the gap.

## Compliance

| Control                          | Istio (current)       | Cilium (target)                         |
| -------------------------------- | --------------------- | --------------------------------------- |
| PCI-DSS 4.0 §4.2.1 (transit)     | Envoy STRICT mTLS     | SPIRE X.509 + WireGuard node encryption |
| SOC2 CC6.1 (logical access)      | `AuthorizationPolicy` | `CiliumNetworkPolicy` + mutual auth     |
| HIPAA §164.312(e)                | Envoy mTLS            | Cilium mutual auth                      |
| PCI-DSS 1.3 (segmentation)       | AuthZ + NetworkPolicy | `CiliumNetworkPolicy` L4+L7             |
| SOC2 CC7.2 / PCI-DSS 10.2 (logs) | Envoy access logs     | Hubble flow export                      |

Update the security control mapping after Phase 3. Hubble can export to CloudWatch via a
custom exporter to preserve the existing audit destination.

## Rollback Summary

| Phase | Action                                                                                  | Difficulty |
| ----- | --------------------------------------------------------------------------------------- | ---------- |
| 1     | `helm uninstall cilium -n kube-system`                                                  | Easy       |
| 2     | Re-add vpc-cni addon, provision VPC-CNI nodes, drain Cilium nodes                       | Hard       |
| 3     | Re-install Istio via Helm, re-enable sidecar injection; flip `encryption.enabled=false` | Medium     |
| 4     | Delete `mtls-require` CCNP, set `authentication.mutual.spire.enabled=false`, restart DS | Easy       |

## Implementation Order

1. **Dev** — Phase 1, validate Cilium + Hubble, then Phase 2, then Phase 3, then Phase 4.
2. **Staging** — same order, off-hours drain for Phase 2; ≥3 days soak before Phase 4.
3. **Prod** — same order, daytime drain for Phase 2 with on-call coverage; 48-hour soak
   after Phase 3; Phase 4 on a quiet-cluster maintenance window only (no concurrent
   AMI / Karpenter / Cilium upgrades — see the deadlock note in Phase 4).

