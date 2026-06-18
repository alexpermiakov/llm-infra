# ADR-001: Migrate from AWS VPC CNI + Istio to Cilium

**Status:** Proposed  
**Date:** 2026-04-29  
**Deciders:** Platform Team

---

## Context

Our EKS clusters currently run:

- **CNI**: AWS VPC CNI (managed addon v1.21.1) with prefix delegation and native NetworkPolicy
- **Service mesh**: Istio 1.28.3 in `STRICT` mTLS mode, installed via Helm
- **Progressive delivery**: Argo Rollouts with `trafficRouting.istio.virtualService` for canary weight-based splitting
- **Compliance**: Istio mTLS and access logging satisfies PCI-DSS 4.0 §4.2.1, SOC2 CC6.1, HIPAA §164.312(e)

Istio is the most operationally expensive component in the stack:

- Envoy sidecar added to every pod (~40 MiB RAM + 10 m CPU per pod at minimum)
- Istiod runs 3 replicas in prod (2 GiB RAM each = 6 GiB dedicated)
- Webhook overhead, CRD sprawl, and upgrade coupling to the Kubernetes version
- PeerAuthentication + AuthorizationPolicy + VirtualService + DestinationRule = 4 object types per service

The only remaining reasons Istio was retained were:

1. mTLS between pods (compliance requirement)
2. `trafficRouting.istio` for Argo Rollouts canary splitting

Both are now addressable by Cilium in 2026.

---

## Decision

**Replace AWS VPC CNI + Istio with Cilium in ENI/native mode**, removing the sidecar mesh entirely.

Cilium (v1.17, expected stable in 2026) provides:

| Capability                      | Currently (Istio)                                 | Replacement (Cilium)                                       |
| ------------------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| Transparent mTLS between pods   | Envoy sidecar injection                           | Cilium Mutual Authentication (SPIFFE/SPIRE, WireGuard)     |
| Zero-trust L4 network policy    | `AuthorizationPolicy` CRD                         | `CiliumNetworkPolicy`                                      |
| L7 HTTP policy                  | `AuthorizationPolicy` HTTP rules                  | `CiliumNetworkPolicy` L7 rules                             |
| Argo Rollouts traffic splitting | `trafficRouting.istio.virtualService`             | `trafficRouting.plugins.gatewayAPI` via Cilium Gateway API |
| Observability / access logs     | Envoy access log + `istio_requests_total` metrics | Hubble + `cilium_*` / `hubble_*` metrics                   |
| DNS-based FQDN egress control   | `ServiceEntry` + `DestinationRule`                | `CiliumNetworkPolicy` `toFQDNs`                            |

### Why Cilium can replace Istio now (2026)

- **Cilium Mutual Authentication** (stable in 1.15, hardened in 1.16-1.17): SPIFFE workload identity +
  mTLS at the kernel level via eBPF, no sidecar proxy needed. Satisfies the same PCI-DSS/HIPAA
  in-transit encryption requirements.
- **Hubble** provides per-connection HTTP observability (method, status code, URL) directly from eBPF,
  replacing Envoy's access logs for compliance audit trails.
- **Cilium Gateway API** (stable in 1.15): Implements `HTTPRoute` with `weight`-based traffic splitting,
  which Argo Rollouts supports through the `gatewayAPI` traffic routing plugin.
- **CiliumNetworkPolicy** L7 rules enforce allow/deny on specific HTTP paths and methods — a superset of
  what Istio's `AuthorizationPolicy` provides, enforced in the kernel without a proxy.

---

## Consequences

### Positive

- **~50% reduction in pod overhead** — no Envoy sidecar (40 MiB + 10 m CPU) per pod
- **~6 GiB RAM freed** in prod from removing istiod replicas
- **Simpler security model** — eBPF kernel-level enforcement, harder to bypass than in-process sidecar
- **Faster startup** — no sidecar init container serialisation on pod start
- **Hubble UI** for live traffic visualisation without Kiali
- **Single CNI** — VPC CNI + Cilium chaining is eliminated; one data path

### Negative / Risks

- Argo Rollouts analysis templates use `istio_requests_total` and `istio_request_duration_milliseconds_bucket` — must be rewritten for Hubble/Cilium metrics (`hubble_flows_processed_total`, or application-level metrics)
- AuthorizationPolicy patterns in the helm chart (`authorization-policy.yaml`, `peer-authentication.yaml`, `virtualservice.yaml`) must be replaced with CiliumNetworkPolicy
- Cilium Mutual Authentication requires SPIRE as an identity provider — adds one more component to manage (though small)
- Migration requires replacing nodes (CNI is baked into the node bootstrap) — plan below

---

## Alternatives Considered

### Keep Istio, only migrate CNI

Rejected — retains all Istio operational cost. The only benefit of the CNI migration alone is
slightly better eBPF datapath performance; not worth the work without also removing Istio.

### Cilium chaining mode (Cilium on top of VPC CNI)

Allows policy and Hubble without replacing the CNI. Rejected as a permanent state because it means
running two data paths and forgoing Cilium's eBPF IPAM performance gains. Acceptable as a
**transient step** during migration.

### Linkerd instead of Cilium for mTLS

Linkerd 2.x provides sidecar-less mTLS via a lightweight proxy. However, it does not provide
CNI replacement, and Argo Rollouts does not have a first-class Linkerd traffic routing plugin.
Cilium solves all problems in one component.

### New cluster, migrate workloads

The cleanest 0-downtime option but a significant operational lift (DNS cutover, re-targeting ArgoCD,
re-issuing IAM/IRSA roles, migrating PVs). Recommended only if the in-place migration proves too
risky during staging dry runs.

---

## Related

- Migration runbook: [docs/runbooks/cilium-migration.md](../runbooks/cilium-migration.md)

