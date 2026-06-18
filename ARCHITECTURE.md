# IDP Architecture

## High-Level Overview

```mermaid
flowchart TB
    subgraph gh["GitHub — GitOps source of truth (github.com/org/idp)"]
        direction LR
        ghdev["argocd/applications/dev<br/>← PR branches (ephemeral)"]
        ghstg["argocd/applications/staging<br/>← main branch"]
        ghprod["argocd/applications/prod<br/>← semver tags (v1.2.3)"]
        ghsrc["helm-charts/ · infra/"]
    end

    subgraph org["AWS Organization"]
        direction LR
        subgraph tooling["TOOLING account"]
            ecr[("ECR")]
        end
        subgraph dev["DEV account"]
            devc["EKS + Argo CD"]
        end
        subgraph staging["STAGING account"]
            stgc["EKS + Argo CD"]
        end
        subgraph prod["PROD account"]
            prodc["EKS + Argo CD"]
        end
    end

    gh -.->|Argo CD syncs| devc
    gh -.->|Argo CD syncs| stgc
    gh -.->|Argo CD syncs| prodc
    ecr ==>|cross-account image pull| devc
    ecr ==>|cross-account image pull| stgc
    ecr ==>|cross-account image pull| prodc
```

## Multi-Region Disaster Recovery (Active-Passive)

> **Status: scaffolded but disabled.** The secondary region's config and the `dns-failover` module exist but are not wired into `infra/entry/main.tf` and no workflow provisions them. The design below is what turning it on yields.

```mermaid
flowchart TB
    r53["Route 53<br/>failover policy + health checks (every 30s)"]
    r53 ==>|primary| pw
    r53 -.->|failover on 3 failed checks| pe

    subgraph pw["PRIMARY — us-west-2 (ACTIVE)"]
        albw["ALB"] --> ekw["EKS cluster"]
    end
    subgraph pe["SECONDARY — us-east-1 (PASSIVE / disabled)"]
        albe["ALB"] --> eke["EKS cluster"]
    end

    ekw <-->|ECR cross-region image replication| eke
```

**Failover time** ≈ 2–3 min = 3 consecutive failed health checks (~90s) + DNS TTL.

**Recovery:** fix the primary → health checks pass → Route 53 marks PRIMARY healthy → traffic returns automatically.

## Deployment Flow

A change starts in an app team's own repo and reaches production without the developer
touching Kubernetes, Terraform, or this repo by hand. CI is the only writer to the GitOps
source of truth; Argo CD is the only writer to the cluster.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as App Team Repo
    participant CI as GitHub Actions (CI)
    participant ECR as ECR (tooling acct)
    participant Plat as Platform Repo (GitOps SoT)
    participant Argo as Argo CD (per env)
    participant K8s as EKS + Argo Rollouts

    Dev->>CI: git tag v1.2.3
    CI->>CI: Quality gate (lint · test · race)
    CI->>CI: Build · Trivy scan · SBOM · Cosign sign
    CI->>ECR: Push signed image
    CI->>Plat: Open PR (bump image tag)
    Note over Plat: Human review + merge
    Plat->>Argo: Merge detected
    Argo->>K8s: Sync manifests
    K8s->>K8s: Progressive rollout<br/>(canary / blue-green, auto-pause)
    K8s-->>Argo: Healthy → promote (or auto-abort)
```

### Environment promotion

The same artifact is promoted across environments by **what git ref points at it** — no rebuilds.

```mermaid
flowchart LR
    pr["PR branch"] -->|ephemeral| dev["dev account<br/>(spun up per PR)"]
    main["main"] -->|auto-sync| staging["staging account"]
    tag["semver tag<br/>v1.2.3"] -->|release| prod["prod account"]
```

## EKS Cluster Components

```mermaid
flowchart TB
    subgraph sys["System namespaces"]
        direction LR
        ks["kube-system<br/>CoreDNS · Karpenter<br/>AWS LBC · Cilium DS"]
        mon["monitoring<br/>Prometheus · Grafana<br/>Alertmanager · Hubble"]
        ky["kyverno<br/>policy engine<br/>admission control"]
        ag["argocd<br/>GitOps sync"]
        cil["cilium<br/>operator · Hubble UI<br/>WireGuard"]
    end

    subgraph apps["Application namespaces — sidecar-less, Cilium dataplane"]
        direction LR
        os["order-service"]
        lc["llm-client"]
        ys["&lt;your-svc&gt;"]
    end

    subgraph nodes["Node management — Karpenter"]
        direction LR
        boot["Bootstrap nodes<br/>t3.medium, tainted<br/>(always on)"]
        managed["Managed nodes<br/>spot / on-demand<br/>(scale 0→N on demand)"]
    end

    inherit["Every app namespace inherits from the golden-path chart:<br/>Rollout · Service · HPA · PDB · NetworkPolicy · CiliumNetworkPolicy (L3/L4/L7 authz)"]
    apps -.-> inherit
```

## Security Architecture

**Defense in depth** — a request crosses four enforcement points before reaching application code:

```mermaid
flowchart LR
    net["Internet"] --> waf["AWS WAF<br/>OWASP · rate limit · bot · IP rep"]
    waf --> npol["Network policy<br/>default-deny + explicit allow"]
    npol --> adm["Admission control<br/>Kyverno"]
    adm --> pss["Pod security<br/>runAsNonRoot · readOnlyFS · drop ALL"]
    pss --> pod["Application pod"]
```

The control domains behind those points:

```mermaid
flowchart TB
    subgraph perimeter["Perimeter — AWS WAF"]
        p["OWASP Top 10 · rate limiting · SQLi / XSS<br/>bot detection · IP reputation<br/>CloudWatch logs (90-day retention)"]
    end
    subgraph admission["Admission control — Kyverno"]
        a["require-labels · pod-security baseline · deny-privileged<br/>audit → enforce (prod enforces)"]
    end
    subgraph runtime["Runtime security"]
        r["Pod Security Standards (baseline → restricted)<br/>securityContext: runAsNonRoot · readOnlyFS · drop ALL<br/>Falco eBPF runtime detection"]
    end
    subgraph network["Network security"]
        n["NetworkPolicy default-deny (DNS + HTTPS only)<br/>namespace isolation<br/>Cilium L3/L4/L7 authorization"]
    end
    subgraph identity["Identity — IAM / IRSA"]
        i["IRSA per service · no long-lived credentials<br/>OIDC federated trust · MFA for humans"]
    end
    subgraph encryption["Encryption at rest"]
        e["KMS for secrets · EBS / gp3 encrypted by default<br/>key rotation enabled"]
    end
```

### Cilium dataplane — WireGuard encryption in transit

```mermaid
flowchart TB
    op["cilium-operator + cilium-agent DaemonSet<br/>• per-node WireGuard keys (auto-rotated)<br/>• enforces L3/L4/L7 CiliumNetworkPolicy<br/>• Hubble exports flow telemetry to Prometheus"]
    op --> svcA
    op --> svcB
    subgraph svcA["Service A"]
        ca["App container"]
    end
    subgraph svcB["Service B"]
        cb["App container"]
    end
    ca <-->|WireGuard, node-to-node| cb
```

Compliance controls satisfied by this layer:

- **PCI-DSS 4.0 §4.2.1** — strong cryptography for data in transit
- **SOC 2 CC6.1** — logical access controls (CiliumNetworkPolicy)
- **HIPAA §164.312(e)** — transmission security
- **FedRAMP SC-8** — transmission confidentiality
- **Zero-trust** — default-deny + explicit identity-based allows

### Image security & supply chain

- Trivy vulnerability scanning in CI — **CRITICAL findings block the deployment**
- Cosign keyless signing + CycloneDX SBOM attestation
- ECR cross-account pull with organization check
- Immutable image tags

## Observability Stack

```mermaid
flowchart LR
    prom["Prometheus<br/>SLIs · SLOs · metrics"] --> am["Alertmanager<br/>routing · grouping · silence"]
    am --> graf["Grafana<br/>SLO · cluster · Kyverno dashboards"]
    am --> rb["Runbooks<br/>SLO burn · high latency · pod crash"]
    prom --> kc["Kubecost<br/>cost by namespace / team / workload"]
```

