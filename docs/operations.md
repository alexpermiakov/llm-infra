# Day-2 Operations

Recurring operational tasks for a **running** cluster — observability, progressive
delivery, capacity, and verification.

- First-time cluster provisioning → [SETUP.md](../SETUP.md)
- Migrations, incident response, disaster recovery → [docs/runbooks/](runbooks/)

## Contents

1. [Prerequisites](#prerequisites)
2. [Cluster & node health](#cluster--node-health)
3. [Verify node-to-node encryption (WireGuard)](#verify-node-to-node-encryption-wireguard)
4. [Network observability — Hubble](#network-observability--hubble)
5. [Progressive delivery — Argo Rollouts](#progressive-delivery--argo-rollouts)
6. [Monitoring stack — Grafana / Prometheus / Alertmanager](#monitoring-stack--grafana--prometheus--alertmanager)
7. [ArgoCD](#argocd)
8. [Application access](#application-access)
9. [Capacity & cost — Karpenter / Kubecost](#capacity--cost--karpenter--kubecost)
10. [Kubernetes version upgrades](#kubernetes-version-upgrades)

---

## Prerequisites

All commands assume your kubeconfig points at the target cluster:

```bash
# Replace <PR> with your PR number (dev); staging/prod use a fixed cluster name
aws eks update-kubeconfig --region us-west-2 --name k8s-pr-<PR>
kubectl get nodes
```

See [SETUP.md → Connect to EKS Cluster](../SETUP.md#connect-to-eks-cluster) for SSO login.

---

## Cluster & node health

### Resource usage

`kubectl top` is served by the **metrics-server** addon — if it errors with
`Metrics API not available`, metrics-server is down, not your command.

```bash
# Per-node CPU / memory usage vs. capacity
kubectl top nodes

# Per-pod usage across all namespaces, hottest first
kubectl top pods -A --sort-by=cpu
kubectl top pods -A --sort-by=memory

# What is *requested/limited* on a node vs. what is allocatable
# (scheduling pressure shows up here before `top` does)
kubectl describe node <node> | grep -A6 'Allocated resources'

# Node inventory: instance type, AZ, capacity type, which CNI/pool
kubectl get nodes -o wide \
  -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone,karpenter.sh/capacity-type,karpenter.sh/nodepool
```

### Quick triage

```bash
# Pods that are not Running/Succeeded (catches Pending, Failed)
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# CrashLoopBackOff hides as phase=Running — sort by restart count instead
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail

# Recent cluster events, newest last
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# Logs for a workload (previous container after a crash: add -p)
kubectl logs -n <namespace> deploy/<name> --tail=100 -f
```

---

## Verify node-to-node encryption (WireGuard)

Cilium encrypts all pod-to-pod traffic that crosses a node boundary, using kernel
WireGuard (`encryption.type=wireguard`, `nodeEncryption=true` in
[infra/modules/cilium/main.tf](../infra/modules/cilium/main.tf)). Verify in three
levels, fast to definitive.

### 1. Agent status (fast)

```bash
kubectl -n kube-system exec ds/cilium -- cilium status | grep -i encryption
# Expect: Encryption: Wireguard [NodeEncryption: Enabled, cilium_wg0 (Pubkey: ..., Port: 51871, Peers: N)]

kubectl -n kube-system exec ds/cilium -- cilium encrypt status
# Expect: Encryption: Wireguard
#         Interface: cilium_wg0
#         Number of peers: <cluster node count − 1>
```

### 2. Check every agent

`exec ds/cilium` only reaches **one** pod. Encryption is only as good as the
weakest node — confirm every agent has a full peer set:

```bash
NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  peers=$(kubectl -n kube-system exec "$pod" -- cilium encrypt status \
    | awk -F': ' '/Number of peers/ {print $2}')
  echo "$pod  peers=$peers  (expected $((NODES - 1)))"
done
```

A peer count below `nodes − 1` means an agent is missing a peer's WireGuard public
key — traffic to/from that node silently falls back to plaintext. Investigate
before trusting the control.

### 3. Inspect the tunnel

```bash
# Per-peer handshakes + byte counters. Non-zero, growing transfer = real
# encrypted traffic is flowing, not just a configured-but-idle interface.
kubectl -n kube-system exec ds/cilium -- wg show cilium_wg0
```

### 4. Definitive — assert ciphertext on the wire

`cilium connectivity test` adds encryption test cases automatically when encryption
is enabled: it generates cross-node pod traffic and sniffs the node underlay to
assert the packets are encrypted.

```bash
cilium connectivity test
# Look for the pod-to-pod / node-to-node encryption test cases passing.
```

For a manual spot-check, capture on a node's primary ENI (e.g. from an SSM session
on the instance) while generating cross-node pod traffic: encrypted traffic appears
as UDP/51871 and carries no readable L7 payload.

> Compliance context (PCI-DSS §4.2.1, HIPAA §164.312(e)) and the staged rollout
> are in [docs/runbooks/cilium-migration.md](runbooks/cilium-migration.md) Phase 3.

---

## Network observability — Hubble

Hubble is Cilium's flow-visibility layer (L3–L7) — it shows live pod-to-pod
connections, DNS, HTTP verdicts, and policy drops.

```bash
# Hubble UI — http://localhost:8881
kubectl port-forward -n kube-system svc/hubble-ui 8881:80
```

CLI (no port-forward needed) for scripted checks and incident triage:

```bash
kubectl -n kube-system exec ds/cilium -- hubble status

# Live L7 HTTP flows with verdicts
kubectl -n kube-system exec ds/cilium -- hubble observe --type l7 --protocol http

# Only dropped traffic — first stop when a connection "just fails"
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED
```

---

## Progressive delivery — Argo Rollouts

```bash
# Port-forward dashboard (default chart service name)
kubectl port-forward -n argo-rollouts svc/argo-rollouts-dashboard 3100:3100

# Trigger a new revision (required to see canary steps) by patching a pod template annotation.
# This changes the pod template hash so Argo Rollouts creates a new revision and runs canary steps.
# Note: `kubectl argo rollouts restart` does NOT create a new revision — it just cycles pods in place.
kubectl patch rollout order-service -n order-service \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}}}}}'

# To watch ALB canary weights live during rollout progression:
# All services share a single ALB via group.name=idp-services, so tag-based lookup by
# namespace/ingress-name won't find it. Instead, read the ALB hostname directly from
# the ingress status — kubectl already knows it from the LBC reconciliation.
NAMESPACE="order-service"

INGRESS_NAME="order-service"

# Step 1: find the ALB ARN via the ingress status hostname (no tag scanning needed)
ALB_DNS=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"

ALB_ARN=$(aws elbv2 describe-load-balancers --region us-west-2 \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].LoadBalancerArn" \
  --output text)
echo "ALB ARN: $ALB_ARN"

# Step 2: get the listener ARN — prefer 443 (prod/staging with TLS), fall back to 80 (dev)
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --region us-west-2 \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners | sort_by(@, &Port) | reverse(@) | [0].ListenerArn" \
  --output text)
echo "Listener ARN: $LISTENER_ARN"

# Step 3: watch the canary vs stable weights on that listener (updates every 5s)
# Double quotes are required so $LISTENER_ARN expands before watch runs the command
watch -n 5 "aws elbv2 describe-rules --region us-west-2 --listener-arn \"$LISTENER_ARN\" | \
  jq -r '.Rules[].Actions[] | select(.Type==\"forward\") | \
    .ForwardConfig.TargetGroups[] | \"\(.Weight)%\t\(.TargetGroupArn | split(\"/\")[1])\"'"


# Use the namespace dropdown in the UI to switch between services.
# Or inspect a specific rollout via CLI:
kubectl argo rollouts get rollout order-service -n order-service --watch
```

---

## Monitoring stack — Grafana / Prometheus / Alertmanager

```bash
# Grafana (dashboards) - http://localhost:3000
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Prometheus (metrics) - http://localhost:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

# Alertmanager (alerts) - http://localhost:9093
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```

Grafana login: username `admin`, password is set via Terraform variable `grafana_admin_password`.

> Cilium and Hubble metrics only appear in Grafana once the Cilium module is
> applied with `enable_service_monitors=true` — see
> [docs/runbooks/cilium-migration.md](runbooks/cilium-migration.md) "Second apply:
> turn ServiceMonitors back on".

---

## ArgoCD

```bash
# Initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo

# Port-forward to ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Access at http://localhost:8080 and login with username `admin` and the password from above.

---

## Application access

## Order Service

```bash
kubectl port-forward -n order-service svc/order-service 8001:80
```

### LLM Client

```bash
# Forward llm-client to localhost (Service port is 80 → container 8080)
kubectl port-forward -n llm-client svc/llm-client 8002:80

# Ask a question (proxied to vLLM /v1/completions)
curl "http://localhost:8002/ask?prompt=The+best+medication+for+headache+is"
```

---

## Capacity & cost — Karpenter / Kubecost

### Monitor Karpenter

```bash
# View Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f

# View provisioned nodes
kubectl get nodes -l karpenter.sh/registered=true

# View NodePool status
kubectl describe nodepool default
```

### Kubecost dashboard

```bash
kubectl port-forward -n kubecost svc/kubecost-frontend 9091:9090
```

---

## Kubernetes version upgrades

```bash
aws eks describe-addon-versions --kubernetes-version 1.35 \
  --query 'addons[].{name:addonName, latest:addonVersions[0].addonVersion, default:addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion|[0]}' \
  --output table --region=us-west-2
```

