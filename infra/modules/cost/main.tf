# Kubecost provides visibility into cluster spend by namespace, workload, and team.

resource "kubernetes_namespace_v1" "kubecost" {
  metadata {
    name = "kubecost"

    labels = {
      "app.kubernetes.io/managed-by"       = "terraform"
      "purpose"                            = "cost-management"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# https://github.com/kubecost/kubecost/blob/develop/kubecost/values.yaml
resource "helm_release" "kubecost" {
  name       = "kubecost"
  repository = "https://kubecost.github.io/kubecost"
  chart      = "kubecost"
  version    = "3.1.3"
  namespace  = kubernetes_namespace_v1.kubecost.metadata[0].name

  timeout = 900

  values = [
    yamlencode({
      global = {
        clusterId = var.cluster_name
      }

      acknowledged = true

      frontend = {
        enabled = true
        resources = {
          requests = {
            cpu    = "10m"
            memory = var.environment == "prod" ? "55Mi" : "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = var.environment == "prod" ? "128Mi" : "64Mi"
          }
        }
        service = {
          type = "ClusterIP"
          port = 9090
        }
      }

      networkCosts = {
        enabled = false
      }

      ingress = {
        enabled = false
      }

      finopsagent = {
        enabled = var.environment == "prod"
        agent = {
          kubecost = {
            spotLabel      = "eks.amazonaws.com/capacityType"
            spotLabelValue = "SPOT"
          }
        }
      }

      aggregator = {
        enabled = var.environment == "prod"
        resources = {
          requests = {
            cpu    = "100m"
            memory = "2Gi"
          }
        }
        aggregatorDbStorage = {
          storageRequest = "128Gi"
        }
      }

      localStore = {
        enabled = true
        persistentVolume = {
          size = var.environment == "prod" ? "32Gi" : "2Gi"
        }
      }

      forecasting = {
        enabled = var.environment == "prod"
      }

      cloudCost = {
        enabled = var.environment == "prod"
      }

      clusterController = {
        enabled = var.environment == "prod"
      }

      kubecostProductConfigs = {
        clusterProfile    = var.environment == "prod" ? "production" : "development"
        currencyCode      = "USD"
        shareTenancyCosts = true
      }
    })
  ]
}
