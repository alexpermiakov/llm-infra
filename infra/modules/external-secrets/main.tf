# Deploys External Secrets Operator to sync secrets from AWS Secrets Manager to Kubernetes.
# Automatically syncs secrets without requiring application redeployment.

terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }

  timeouts {
    delete = "15m"
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "1.2.1"
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name

  wait             = true
  timeout          = 600
  create_namespace = false

  values = [
    yamlencode({
      installCRDs = true

      webhook = {
        port          = 9443
        failurePolicy = "Ignore"
      }

      serviceAccount = {
        create = true
        name   = "external-secrets"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets.arn
        }
      }

      securityContext = {
        runAsNonRoot = true
        runAsUser    = 1000
        fsGroup      = 1000
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "256Mi"
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.external_secrets]
}

resource "aws_iam_role" "external_secrets" {
  name = "${var.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets"
            "${var.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-external-secrets"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "external-secrets-policy"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:argocd/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = [var.kms_key_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/idp/${var.environment}/*"
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

resource "time_sleep" "wait_for_webhook" {
  depends_on      = [helm_release.external_secrets]
  create_duration = "30s"
}

resource "kubectl_manifest" "secret_store" {
  validate_schema = false
  ignore_fields   = ["metadata.finalizers"]

  lifecycle {
    create_before_destroy = false
  }

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secretsmanager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })

  depends_on = [time_sleep.wait_for_webhook]
}

resource "kubectl_manifest" "github_app_external_secret" {
  depends_on = [kubectl_manifest.secret_store]

  wait              = false
  wait_for_rollout  = false
  server_side_apply = true
  force_conflicts   = true
  validate_schema   = false
  ignore_fields     = ["metadata.finalizers"]

  lifecycle {
    create_before_destroy = false
    ignore_changes        = all
  }

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "github-repo-creds"
      namespace = var.argocd_namespace
      labels = {
        "argocd.argoproj.io/secret-type" = "repo-creds"
      }
    }
    spec = {
      refreshInterval = "1m"
      secretStoreRef = {
        name = "aws-secretsmanager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "github-repo-creds"
        creationPolicy = "Owner"
        template = {
          metadata = {
            labels = {
              "argocd.argoproj.io/secret-type" = "repo-creds"
            }
          }
          data = {
            type                    = "git"
            url                     = "https://github.com/${var.github_org}"
            githubAppID             = "{{ .appID }}"
            githubAppInstallationID = "{{ .installationID }}"
            githubAppPrivateKey     = "{{ .privateKey }}"
          }
        }
      }
      dataFrom = [
        {
          extract = {
            key = var.github_app_secret_name
          }
        }
      ]
    }
  })
}

# Stakater Reloader - automatically restarts deployments when secrets/configmaps change
resource "helm_release" "reloader" {
  name       = "reloader"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = "2.2.7"
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name

  wait = true

  values = [
    yamlencode({
      reloader = {
        watchGlobally  = true
        isArgoRollouts = true # also watch Argo Rollouts for changes
        deployment = {
          resources = {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }
      }
    })
  ]

  depends_on = [helm_release.external_secrets]
}
