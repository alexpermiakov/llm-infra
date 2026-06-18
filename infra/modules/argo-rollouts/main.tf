# Argo Rollouts for progressive delivery (Canary/Blue-Green deployments)
# Enables gradual traffic shifting with automatic rollback based on metrics
# https://argo-rollouts.readthedocs.io/

terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

data "aws_region" "current" {}

resource "aws_iam_role" "argo_rollouts" {
  name = "${var.cluster_name}-argo-rollouts"

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
            "${var.oidc_provider}:sub" = "system:serviceaccount:argo-rollouts:argo-rollouts"
            "${var.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-argo-rollouts"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy" "argo_rollouts_alb_verification" {
  name = "argo-rollouts-alb-verification"
  role = aws_iam_role.argo_rollouts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeAlbState"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "kubernetes_namespace_v1" "argo_rollouts" {
  metadata {
    name = "argo-rollouts"

    labels = {
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# https://github.com/argoproj/argo-helm/tree/main/charts/argo-rollouts
resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = "2.40.5"
  namespace  = kubernetes_namespace_v1.argo_rollouts.metadata[0].name

  timeout = 600

  values = [
    yamlencode({
      providerRBAC = {
        enabled = true
        providers = {
          awsLoadBalancerController = true
        }
      }

      serviceAccount = {
        create = true
        name   = "argo-rollouts"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.argo_rollouts.arn
        }
      }

      controller = {
        replicas             = var.environment == "prod" ? 2 : 1
        awsVerifyTargetGroup = true

        extraEnv = [
          {
            name  = "AWS_REGION"
            value = data.aws_region.current.id
          }
        ]

        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "256Mi"
          }
        }

        metrics = {
          enabled = true
          serviceMonitor = {
            enabled   = true
            namespace = "monitoring"
          }
        }
      }

      dashboard = {
        enabled  = true
        readonly = var.environment == "prod"

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

        service = {
          type = "ClusterIP"
          port = 3100
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.argo_rollouts,
    aws_iam_role_policy.argo_rollouts_alb_verification,
  ]
}

# https://argo-rollouts.readthedocs.io/en/stable/analysis/prometheus/
resource "kubectl_manifest" "canary_analysis_template" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ClusterAnalysisTemplate"
    metadata = {
      name = "success-rate"
    }
    spec = {
      args = [
        { name = "service-name" },
        { name = "namespace" },
        # count makes the metric terminate. Required when the template is used as a
        # blueGreen prePromotion gate (an indefinite metric is rejected as invalid);
        # canary background analysis overrides it with a larger value.
        { name = "count", value = "5" }
      ]
      metrics = [
        {
          name     = "success-rate"
          interval = "30s"
          count    = "{{args.count}}"
          # Require at least 99% success rate during canary
          # Uses Hubble L7 HTTP metrics (httpV2 enabled in Cilium values)
          successCondition = "result[0] >= 0.99"
          failureLimit     = 3
          provider = {
            prometheus = {
              address = "http://kube-prometheus-stack-prometheus.monitoring:9090"
              query   = <<-EOQ
                (
                  sum(rate(hubble_http_requests_total{status!~"5..",destination_workload="{{args.service-name}}",destination_workload_namespace="{{args.namespace}}"}[5m]))
                  /
                  sum(rate(hubble_http_requests_total{destination_workload="{{args.service-name}}",destination_workload_namespace="{{args.namespace}}"}[5m]))
                ) or vector(1)
              EOQ
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.argo_rollouts]
}

# General-purpose check: canary is receiving traffic and serving it successfully
resource "kubectl_manifest" "request_throughput_analysis_template" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ClusterAnalysisTemplate"
    metadata = {
      name = "request-throughput"
    }
    spec = {
      args = [
        { name = "service-name" },
        { name = "namespace" },
        { name = "min-rps", value = "0.1" },
        { name = "count", value = "5" }
      ]
      metrics = [
        {
          name     = "successful-request-throughput"
          interval = "30s"
          count    = "{{args.count}}"
          # Ensure the canary is actually receiving AND successfully handling requests
          # Counts non-5xx responses per second over a 5m window
          # initialDelay gives the rate window time to accumulate canary traffic
          successCondition = "result[0] >= {{args.min-rps}}"
          failureLimit     = 5
          provider = {
            prometheus = {
              address = "http://kube-prometheus-stack-prometheus.monitoring:9090"
              query   = <<-EOQ
                sum(
                  rate(
                    hubble_http_requests_total{
                      status!~"5..",
                      destination_workload="{{args.service-name}}",
                      destination_workload_namespace="{{args.namespace}}"
                    }[5m]
                  )
                ) or vector(0)
              EOQ
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.argo_rollouts]
}

resource "kubectl_manifest" "latency_analysis_template" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ClusterAnalysisTemplate"
    metadata = {
      name = "latency-check"
    }
    spec = {
      args = [
        { name = "service-name" },
        { name = "namespace" },
        { name = "latency-threshold", value = "0.5" }, # Default 500ms (Hubble metrics are in seconds)
        { name = "count", value = "5" }
      ]
      metrics = [
        {
          name     = "p99-latency"
          interval = "30s"
          count    = "{{args.count}}"
          # P99 latency must be under threshold (seconds)
          # Uses Hubble L7 HTTP duration histogram with fallback for no data
          successCondition = "result[0] < {{args.latency-threshold}}"
          failureLimit     = 3
          provider = {
            prometheus = {
              address = "http://kube-prometheus-stack-prometheus.monitoring:9090"
              query   = <<-EOQ
                (
                  histogram_quantile(0.99,
                    sum(rate(hubble_http_request_duration_seconds_bucket{destination_workload="{{args.service-name}}",destination_workload_namespace="{{args.namespace}}"}[5m])) by (le)
                  )
                ) or vector(0)
              EOQ
            }
          }
        }
      ]
    }
  })

  depends_on = [helm_release.argo_rollouts]
}
