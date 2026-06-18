# Deploys the observability stack: Prometheus, Grafana, and Alertmanager.
# https://github.com/prometheus-community/helm-charts

terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"

    labels = {
      "app.kubernetes.io/managed-by"       = "terraform"
      "purpose"                            = "observability"
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "67.9.0"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  wait         = false
  force_update = true

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          retention     = var.environment == "prod" ? "15d" : "7d"
          retentionSize = var.environment == "prod" ? "10GB" : "5GB"

          resources = {
            requests = {
              cpu    = var.environment == "prod" ? "500m" : "250m"
              memory = var.environment == "prod" ? "1Gi" : "512Mi"
            }
            limits = {
              cpu    = var.environment == "prod" ? "1000m" : "500m"
              memory = var.environment == "prod" ? "2Gi" : "1Gi"
            }
          }

          securityContext = {
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }

          podMonitorSelectorNilUsesHelmValues     = false
          serviceMonitorSelectorNilUsesHelmValues = false
          ruleSelectorNilUsesHelmValues           = false

          storageSpec = var.environment != "dev" ? {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = var.environment == "prod" ? "50Gi" : "20Gi"
                  }
                }
              }
            }
          } : null
        }
      }

      # https://github.com/grafana/helm-charts/tree/main/charts/grafana
      grafana = {
        enabled = true

        adminPassword = var.grafana_admin_password

        containerSecurityContext = {
          allowPrivilegeEscalation = false
          capabilities = {
            drop = ["ALL"]
          }
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }

        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "300m"
            memory = "512Mi"
          }
        }

        persistence = {
          enabled          = var.environment != "dev"
          size             = "10Gi"
          storageClassName = "gp3"
        }

        defaultDashboardsEnabled  = true
        defaultDashboardsTimezone = "America/Toronto"

        additionalDataSources = []

        "grafana.ini" = {
          server = {
            root_url = var.grafana_root_url
          }
          auth = {
            disable_login_form = false
            # PCI-DSS 8.1.8, HIPAA §164.312(a)(2)(iii): Session timeout
            # Auto-logout after 15 minutes of inactivity (PCI max)
            login_maximum_inactive_lifetime_duration = "15m"
            login_maximum_lifetime_duration          = "12h"
          }
          "auth.anonymous" = {
            enabled = var.environment == "dev"
          }
          security = {
            admin_user      = "admin"
            allow_embedding = true
          }
          explore = {
            enabled = true
          }
          news = {
            news_feed_enabled = false
          }
        }

        sidecar = {
          dashboards = {
            enabled          = true
            searchNamespace  = "ALL"
            label            = "grafana_dashboard"
            folderAnnotation = "grafana_folder"
          }
          datasources = {
            enabled         = true
            searchNamespace = "ALL"
            label           = "grafana_datasource"
          }
        }
      }

      # https://github.com/prometheus-community/helm-charts/blob/main/charts/alertmanager/values.yaml
      alertmanager = {
        enabled = true

        alertmanagerSpec = {
          securityContext = {
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }

          resources = {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          storage = var.environment != "dev" ? {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "5Gi"
                  }
                }
              }
            }
          } : null
        }
      }

      prometheusOperator = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }

      kubeStateMetrics = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      nodeExporter = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "64Mi"
          }
        }
      }

      # Disable rules for EKS-managed components (not accessible to scrape)
      defaultRules = {
        create = true
        rules = {
          etcd                   = false
          kubeControllerManager  = false
          kubeProxy              = false
          kubeSchedulerAlerting  = false
          kubeSchedulerRecording = false
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

# https://github.com/grafana/loki/blob/main/production/helm/loki/values.yaml
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.23.0"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # Loki's StatefulSet can leave Helm releases in a pending/failed state
  replace = true
  wait    = false

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"

      # Service account with IRSA for S3 access
      serviceAccount = {
        create = true
        name   = "loki"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.loki_logs_bucket.irsa_role_arn
        }
      }

      loki = {
        auth_enabled = false

        commonConfig = {
          replication_factor = var.environment == "prod" ? 3 : 1
        }

        storage = {
          type = "s3"
          bucketNames = {
            chunks = module.loki_logs_bucket.bucket_id
            ruler  = module.loki_logs_bucket.bucket_id
            admin  = module.loki_logs_bucket.bucket_id
          }
          s3 = {
            region = data.aws_region.current.id
          }
        }

        schemaConfig = {
          configs = [
            {
              from         = "2024-01-01"
              store        = "tsdb"
              object_store = "s3"
              schema       = "v13"
              index = {
                prefix = "index_"
                period = "24h"
              }
            }
          ]
        }

        # Retention period (logs stored in S3 with lifecycle policy)
        limits_config = {
          retention_period            = var.environment == "prod" ? "2160h" : "720h" # 90 days prod, 30 days dev/staging
          max_query_lookback          = var.environment == "prod" ? "2160h" : "720h"
          max_global_streams_per_user = 10000
          ingestion_rate_mb           = 10
          ingestion_burst_size_mb     = 20
        }

        # Structured metadata for compliance queries
        structuredConfig = var.environment == "prod" ? {
          compactor = {
            retention_enabled = true
          }
        } : {}
      }

      singleBinary = {
        replicas = var.environment == "prod" ? 3 : 1

        podSecurityContext = {
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }

        containerSecurityContext = {
          allowPrivilegeEscalation = false
          capabilities = {
            drop = ["ALL"]
          }
          readOnlyRootFilesystem = true
        }

        resources = {
          requests = {
            cpu    = var.environment == "prod" ? "200m" : "100m"
            memory = var.environment == "prod" ? "512Mi" : "256Mi"
          }
          limits = {
            cpu    = var.environment == "prod" ? "1000m" : "500m"
            memory = var.environment == "prod" ? "1Gi" : "512Mi"
          }
        }

        # Local persistence for index/cache even with S3 backend
        persistence = {
          enabled          = true
          size             = var.environment == "prod" ? "20Gi" : "10Gi"
          storageClassName = "gp3"
        }
      }

      backend = {
        replicas = 0
      }
      read = {
        replicas = 0
      }
      write = {
        replicas = 0
      }

      gateway = {
        enabled = false
      }

      # Disable memcached caches - not needed for SingleBinary mode
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.16.6"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  wait = false

  values = [
    yamlencode({
      config = {
        clients = [
          {
            url = "http://loki:3100/loki/api/v1/push"
          }
        ]

        snippets = {
          # Drop high-volume, low-value logs before shipping to Loki
          pipelineStages = [
            {
              drop = {
                source     = ""
                expression = "(?i)(GET|HEAD) (/health[z]?|/ready|/readiness|/live[z]?|/liveness|/metrics|/ping|/favicon.ico)([?\\s]|$)"
              }
            },
            # (Kubernetes health checks)
            {
              drop = {
                source     = ""
                expression = "kube-probe/"
              }
            },
            # (AWS ALB/ELB health checks)
            {
              drop = {
                source     = ""
                expression = "ELB-HealthChecker/"
              }
            },
            # (Empty or whitespace-only log lines)
            {
              drop = {
                source     = ""
                expression = "^\\s*$"
              }
            },
            # PII/PHI Redaction for HIPAA & PCI-DSS Compliance
            # HIPAA §164.312(e)(1), PCI-DSS 3.4
            # Redact Social Security Numbers (SSN)
            {
              replace = {
                expression = "\\b\\d{3}-\\d{2}-\\d{4}\\b"
                replace    = "[REDACTED-SSN]"
              }
            },
            # Redact Credit Card Numbers (PCI-DSS)
            {
              replace = {
                expression = "\\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\\b"
                replace    = "[REDACTED-PAN]"
              }
            },
            # Redact Email Addresses
            {
              replace = {
                expression = "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b"
                replace    = "[REDACTED-EMAIL]"
              }
            },
            # Redact US Phone Numbers
            {
              replace = {
                expression = "\\b(?:\\+?1[-.]?)?\\(?[0-9]{3}\\)?[-.]?[0-9]{3}[-.]?[0-9]{4}\\b"
                replace    = "[REDACTED-PHONE]"
              }
            },
            # Redact potential Medical Record Numbers (MRN)
            {
              replace = {
                expression = "\\b(?i)MRN[:\\s-]*[A-Z0-9]{6,12}\\b"
                replace    = "[REDACTED-MRN]"
              }
            },
            # Redact AWS Access Keys
            {
              replace = {
                expression = "\\b(?:AKIA|ABIA|ACCA|ASIA)[A-Z0-9]{16}\\b"
                replace    = "[REDACTED-AWS-KEY]"
              }
            },
            # Redact Bearer Tokens and API Keys
            {
              replace = {
                expression = "(?i)(bearer|api[_-]?key|token|secret|password)[\\s:=]+['\"]?[A-Za-z0-9_\\-\\.]{20,}['\"]?"
                replace    = "$1=[REDACTED]"
              }
            }
          ]
        }
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "128Mi"
        }
      }
    })
  ]

  depends_on = [helm_release.loki]
}

resource "kubernetes_config_map_v1" "grafana_loki_datasource" {
  metadata {
    name      = "grafana-datasource-loki"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          url       = "http://loki:3100"
          access    = "proxy"
          isDefault = false
        }
      ]
    })
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

module "dashboards" {
  source = "./dashboards"

  namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

  depends_on = [helm_release.kube_prometheus_stack]
}
