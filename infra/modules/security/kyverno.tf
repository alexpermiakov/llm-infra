# Deploys Kyverno for policy enforcement.
# Enforces Pod Security Standards and detects anomalous container behavior.
# https://kyverno.io/docs/introduction/how-kyverno-works/

terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

# IRSA role for Kyverno to authenticate to cross-account ECR when verifying image signatures.
# Without this, Kyverno's verify-image-signatures policy gets 401 from ECR.
module "kyverno_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.3.0"

  name = "${var.cluster_name}-kyverno"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kyverno:kyverno-admission-controller", "kyverno:kyverno-background-controller"]
    }
  }

  policies = {
    kyverno_ecr = aws_iam_policy.kyverno_ecr.arn
  }

  tags = {
    Purpose = "kyverno-image-verification"
  }
}

resource "aws_iam_policy" "kyverno_ecr" {
  name = "${var.cluster_name}-kyverno-ecr"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = ["arn:aws:ecr:*:${var.ecr_account_id}:repository/idp/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      }
    ]
  })
}

resource "helm_release" "kyverno" {
  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = "3.6.2"

  timeout = 600

  values = [
    yamlencode({
      admissionController = {
        replicas = var.environment == "prod" ? 3 : 1
        serviceMonitor = {
          enabled = true
        }
        logging = {
          format    = "json"
          verbosity = 2 # Info level - captures admission decisions
        }
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = module.kyverno_irsa.arn
          }
        }
      }
      backgroundController = {
        replicas = var.environment == "prod" ? 2 : 1
        serviceMonitor = {
          enabled = true
        }
        logging = {
          format    = "json"
          verbosity = 2
        }
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = module.kyverno_irsa.arn
          }
        }
      }
      cleanupController = {
        replicas = 1
        serviceMonitor = {
          enabled = true
        }
      }
      reportsController = {
        replicas = 1
        serviceMonitor = {
          enabled = true
        }
      }
    })
  ]
}

resource "kubectl_manifest" "kyverno_require_labels" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-labels"
      annotations = {
        "policies.kyverno.io/title"       = "Require Labels"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "low"
        "policies.kyverno.io/description" = "Require app and team labels on Deployments"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "check-labels"
          match = {
            any = [{ resources = { kinds = ["Deployment", "StatefulSet"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "kubecost", "argocd", "argo-rollouts", "falco-system", "external-secrets"] } }
            ]
          }
          validate = {
            message = "Deployments must have 'app' and 'team' labels"
            pattern = {
              metadata = {
                labels = {
                  app  = "?*"
                  team = "?*"
                }
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# PCI-DSS 1.3, SOC2 CC6.6: Require network segmentation via NetworkPolicy
resource "kubectl_manifest" "kyverno_require_networkpolicy" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-networkpolicy"
      annotations = {
        "policies.kyverno.io/title"       = "Require NetworkPolicy"
        "policies.kyverno.io/category"    = "Network Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Require NetworkPolicy to exist before pods can run (PCI-DSS 1.3, SOC2 CC6.6)"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = false
      rules = [
        {
          name = "check-networkpolicy-exists"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "kubecost", "argocd", "argo-rollouts", "external-secrets"] } }
            ]
          }
          context = [
            {
              name = "networkpolicies"
              apiCall = {
                urlPath  = "/apis/networking.k8s.io/v1/namespaces/{{ request.namespace }}/networkpolicies"
                jmesPath = "items[].metadata.name"
              }
            }
          ]
          preconditions = {
            all = [
              {
                key      = "{{ request.operation || 'BACKGROUND' }}"
                operator = "NotEquals"
                value    = "DELETE"
              }
            ]
          }
          validate = {
            message = "NetworkPolicy must exist in namespace before creating pods (PCI-DSS 1.3: network segmentation required)"
            deny = {
              conditions = {
                all = [
                  {
                    key      = "{{ networkpolicies }}"
                    operator = "Equals"
                    value    = []
                  }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_pod_security_baseline" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "pod-security-baseline"
      annotations = {
        "policies.kyverno.io/title"       = "Pod Security Standards - Baseline"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Enforce baseline pod security standards"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "deny-privileged-containers"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "argocd", "argo-rollouts", "monitoring", "amazon-guardduty", "falco-system"] } }
            ]
          }
          validate = {
            message = "Privileged containers are not allowed"
            pattern = {
              spec = {
                containers = [
                  { securityContext = { privileged = "!true" } }
                ]
              }
            }
          }
        },
        {
          name = "deny-host-namespaces"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "argocd", "argo-rollouts", "amazon-guardduty", "falco-system"] } }
            ]
          }
          validate = {
            message = "Host namespaces (hostNetwork, hostPID, hostIPC) are not allowed"
            pattern = {
              spec = {
                "=(hostNetwork)" = false
                "=(hostPID)"     = false
                "=(hostIPC)"     = false
              }
            }
          }
        },
        {
          name = "deny-host-path"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "argocd", "argo-rollouts", "amazon-guardduty", "falco-system"] } }
            ]
          }
          validate = {
            message = "HostPath volumes are not allowed"
            pattern = {
              spec = {
                "=(volumes)" = [
                  { "X(hostPath)" = "null" }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "kyverno_require_limits" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-resource-limits"
      annotations = {
        "policies.kyverno.io/title"       = "Require Resource Limits"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Require CPU and memory limits on all containers"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "check-limits"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "kubecost", "argocd", "argo-rollouts", "falco-system"] } }
            ]
          }
          validate = {
            message = "CPU and memory limits are required for all containers"
            pattern = {
              spec = {
                containers = [
                  {
                    resources = {
                      limits = {
                        memory = "?*"
                        cpu    = "?*"
                      }
                    }
                  }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# HIPAA: Prevent containers from running as root (§164.312(a)(1))
resource "kubectl_manifest" "kyverno_disallow_root" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "disallow-root-user"
      annotations = {
        "policies.kyverno.io/title"       = "Disallow Root User"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Containers must not run as root. HIPAA §164.312(a)(1)"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "check-runasnonroot"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "argocd", "argo-rollouts", "amazon-guardduty", "falco-system"] } }
            ]
          }
          validate = {
            message = "Containers must set runAsNonRoot to true"
            pattern = {
              spec = {
                containers = [
                  { securityContext = { runAsNonRoot = true } }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# HIPAA: Require read-only root filesystem (§164.312(c)(1) - Integrity)
resource "kubectl_manifest" "kyverno_readonly_rootfs" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-readonly-rootfs"
      annotations = {
        "policies.kyverno.io/title"       = "Require Read-Only Root Filesystem"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Containers must use read-only root filesystem. HIPAA §164.312(c)(1)"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "check-readonly-rootfs"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "argocd", "argo-rollouts", "kubecost", "amazon-guardduty", "falco-system"] } }
            ]
          }
          validate = {
            message = "Containers must set readOnlyRootFilesystem to true"
            pattern = {
              spec = {
                containers = [
                  { securityContext = { readOnlyRootFilesystem = true } }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# HIPAA: Drop all capabilities (least privilege - §164.312(a)(1))
resource "kubectl_manifest" "kyverno_drop_capabilities" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "drop-all-capabilities"
      annotations = {
        "policies.kyverno.io/title"       = "Drop All Capabilities"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Containers must drop ALL capabilities. HIPAA §164.312(a)(1)"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "drop-all-caps"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "argocd", "argo-rollouts", "amazon-guardduty", "falco-system"] } }
            ]
          }
          validate = {
            message = "Containers must drop ALL capabilities"
            pattern = {
              spec = {
                containers = [
                  {
                    securityContext = {
                      capabilities = {
                        drop = ["ALL"]
                      }
                    }
                  }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# SOC 2: Require probes for reliability (CC7.1 - System Operations)
resource "kubectl_manifest" "kyverno_require_probes" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-probes"
      annotations = {
        "policies.kyverno.io/title"       = "Require Liveness and Readiness Probes"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Deployments must have liveness and readiness probes. SOC 2 CC7.1"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "check-probes"
          match = {
            any = [{ resources = { kinds = ["Deployment"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "monitoring", "argocd", "kubecost", "argo-rollouts"] } }
            ]
          }
          validate = {
            message = "Deployments must have livenessProbe and readinessProbe configured"
            pattern = {
              spec = {
                template = {
                  spec = {
                    containers = [
                      {
                        livenessProbe  = { "+" = "*" }
                        readinessProbe = { "+" = "*" }
                      }
                    ]
                  }
                }
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# PCI-DSS: Disallow latest tag (6.5.3 - Secure Coding)
resource "kubectl_manifest" "kyverno_disallow_latest" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "disallow-latest-tag"
      annotations = {
        "policies.kyverno.io/title"       = "Disallow Latest Tag"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Images must not use the 'latest' tag. PCI-DSS 6.5.3"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "disallow-latest"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "argo-rollouts"] } }
            ]
          }
          validate = {
            message = "Images must not use the 'latest' tag"
            pattern = {
              spec = {
                containers = [
                  { image = "!*:latest" }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# Restrict image registries to trusted sources only
resource "kubectl_manifest" "kyverno_restrict_registries" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "restrict-image-registries"
      annotations = {
        "policies.kyverno.io/title"       = "Restrict Image Registries"
        "policies.kyverno.io/category"    = "Supply Chain Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Images must come from trusted registries only"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit"
      background              = true
      rules = [
        {
          name = "restrict-registries"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "argocd", "monitoring", "kubecost", "argo-rollouts", "external-secrets", "falco-system"] } }
            ]
          }
          validate = {
            message = "Images must be from allowed registries: ECR, quay.io, ghcr.io, or docker.io library"
            pattern = {
              spec = {
                containers = [
                  {
                    image = "*.dkr.ecr.*.amazonaws.com/* | quay.io/* | ghcr.io/* | docker.io/library/*"
                  }
                ]
              }
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

# Supply Chain Security: Verify image signatures (Cosign/Sigstore)
# Required for: FDA 21 CFR Part 11, PCI-DSS 6.3, SOC 2 CC8.1
resource "kubectl_manifest" "kyverno_verify_image_signatures" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "verify-image-signatures"
      annotations = {
        "policies.kyverno.io/title"       = "Verify Image Signatures"
        "policies.kyverno.io/category"    = "Supply Chain Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Verify that container images are signed with Cosign. FDA 21 CFR Part 11, PCI-DSS 6.3"
      }
    }
    spec = {
      validationFailureAction = var.environment == "prod" ? "Enforce" : "Audit" # Enforce in prod, audit in dev/staging
      background              = true
      webhookTimeoutSeconds   = 30
      rules = [
        {
          name = "verify-signature"
          match = {
            any = [{ resources = { kinds = ["Pod"] } }]
          }
          exclude = {
            any = [
              { resources = { namespaces = ["kube-system", "kyverno", "argocd", "monitoring", "kubecost", "argo-rollouts", "external-secrets", "falco-system"] } }
            ]
          }
          verifyImages = [
            {
              # Verify images from our ECR repository are signed
              imageReferences = [
                "*.dkr.ecr.*.amazonaws.com/idp/*"
              ]
              mutateDigest = var.environment == "prod" ? true : false # Only mutate in prod for enforcement
              attestors = [
                {
                  count = 1
                  entries = [
                    {
                      keyless = {
                        # Sigstore keyless signing via GitHub Actions OIDC
                        # Only accepts signatures from workflows in the trusted GitHub org
                        issuer  = "https://token.actions.githubusercontent.com"
                        subject = "https://github.com/${var.trusted_github_org}/*"
                        rekor = {
                          url = "https://rekor.sigstore.dev"
                        }
                      }
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

