# PCI-DSS 11.5.2: File Integrity Monitoring (FIM)
# PCI-DSS 5.2: Anti-malware/anomaly detection
# HIPAA §164.312(c)(1): Integrity controls
# https://falco.org/docs/ - Detect security threats in pods

resource "helm_release" "falco" {
  count            = 0
  name             = "falco"
  namespace        = "falco-system"
  create_namespace = true
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = "7.2.1"

  timeout = 600

  values = [
    yamlencode({
      driver = {
        kind = "modern_ebpf"
        modern_ebpf = {
          leastPrivileged = true
        }
      }

      # Tty output must be disabled when running as daemonset
      tty = false

      falco = {
        json_output                  = true
        json_include_output_property = true

        log_level = "info"

        grpc = {
          enabled = true
        }
        grpc_output = {
          enabled = true
        }
      }

      # Resource limits - increased for eBPF overhead
      resources = {
        requests = {
          cpu    = "100m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "1000m"
          memory = "1024Mi"
        }
      }

      # Collector configuration for stability (v7.x containerEngine format)
      collectors = {
        enabled = true
        containerEngine = {
          enabled = true
          engines = [
            {
              containerd = {
                socket = "/run/containerd/containerd.sock"
              }
            }
          ]
        }
        kubernetes = { enabled = true }
      }

      # Tolerations to run on all nodes including system nodes
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        },
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]

      # Falcosidekick - forwards alerts to various outputs
      falcosidekick = {
        enabled = true

        serviceAccount = {
          create = true
          annotations = {
            "eks.amazonaws.com/role-arn" = module.falco_logs.iam_role_arn
          }
        }

        config = {
          aws = {
            cloudwatchlogs = {
              loggroup  = module.falco_logs.log_group_name
              logstream = "alerts"
              region    = var.region
            }
            s3 = {
              bucket = var.security_logs_bucket
              region = var.region
              prefix = "falco/${var.cluster_name}"
            }
          }
        }

        webui = {
          enabled = var.environment != "prod"
        }
      }

      serviceMonitor = {
        enabled = true
      }
    })
  ]

  depends_on = [var.eks_cluster_ready, module.falco_logs]
}
