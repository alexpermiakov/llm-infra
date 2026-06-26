# Kyverno policy unit tests

Offline unit tests for the platform's admission-control policies in
[`../`](../). Each policy is the **single source of truth** — Terraform
([`../../kyverno.tf`](../../kyverno.tf)) applies these exact files, and
`kyverno test` evaluates them against good/bad fixtures with **no cluster**.
A typo in a `match`/`exclude`/`validate` block that silently disables a control
turns these red instead of shipping a dead guardrail.

## Run locally

```bash
kyverno test .
```

## What's covered

Each suite asserts a compliant resource **passes** and a violating one **fails**
(the `result: fail` cases prove the policy denies, not just that it parses):

| Suite | Policy | Proves |
| --- | --- | --- |
| `disallow-latest-tag/` | disallow-latest-tag | `:latest` is rejected, pinned tags pass (PCI-DSS 6.5.3) |
| `drop-all-capabilities/` | drop-all-capabilities | missing / partial `drop` is rejected (HIPAA §164.312(a)(1)) |
| `restrict-image-registries/` | restrict-image-registries | untrusted registries are rejected |
| `require-resource-limits/` | require-resource-limits | containers without cpu/memory limits are rejected |

## Deliberately deferred (need the integration layer, not offline tests)

- **require-networkpolicy** — its verdict depends on a live `apiCall` context
  (`{{ networkpolicies }}`). Testable offline only by mocking that context; the
  honest test is on a `kind` cluster (chainsaw) that actually has/lacks a
  NetworkPolicy.
- **verify-image-signatures** — Cosign/Sigstore verification needs real
  signatures and a registry; it belongs in a `kind` + cosign integration test,
  not an offline unit test. (This policy also stays in `kyverno.tf` because it
  carries environment-specific OIDC trust config.)
