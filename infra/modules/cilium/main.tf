# Cilium owns IPAM (allocates pod IPs from VPC ENIs directly) and replaces
# kube-proxy with eBPF service routing.
# See: docs/runbooks/cilium-migration.md

terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
  }
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.17.4"
  namespace  = "kube-system"

  # wait=false: Cilium installs before the bootstrap node group joins, so the
  # DaemonSet has no node to roll out on yet (default wait=true would time out).
  wait         = false
  timeout      = 600
  force_update = true

  # Self-heal a prior failed apply on CI re-runs (purge stale release record).
  replace         = true
  cleanup_on_fail = true

  values = [yamlencode({
    # ── ENI mode ──
    cni = {
      chainingMode = "none"
      exclusive    = true # write Cilium's CNI conf and remove any others on disk
    }

    ipam = {
      mode = "eni"
    }

    eni = {
      enabled               = true
      updateEC2AdapterLimit = true
      # /28 prefix per ENI slot; required to back kubelet max-pods=110.
      awsEnablePrefixDelegation = true
    }

    routingMode           = "native"
    ipv4NativeRoutingCIDR = var.vpc_cidr

    egressMasqueradeInterfaces = "ens+"

    # ── kube-proxy replacement (eBPF) ──
    kubeProxyReplacement = "true"
    k8sServiceHost       = trimprefix(var.cluster_endpoint, "https://")
    k8sServicePort       = "443"

    nodePort = {
      enabled           = true
      enableHealthCheck = false
    }

    # ── Transit encryption (WireGuard node-to-node) ──
    encryption = {
      enabled        = true
      type           = "wireguard"
      nodeEncryption = true
    }

    # ── Hubble observability ──
    hubble = {
      enabled = true

      relay = { enabled = true }

      ui = { enabled = true }

      metrics = {
        enabled = [
          "dns",
          "drop",
          "tcp",
          "flow",
          "port-distribution",
          "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
        ]
        serviceMonitor = {
          enabled        = var.enable_service_monitors
          namespace      = "monitoring"
          trustCRDsExist = true
        }
      }
    }

    # ── Prometheus integration ──
    prometheus = {
      enabled = true
      serviceMonitor = {
        enabled        = var.enable_service_monitors
        namespace      = "monitoring"
        trustCRDsExist = true
      }
    }

    # ── Operator ──
    operator = {
      replicas = var.environment == "prod" ? 2 : 1
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" },
        { operator = "Exists" }
      ]
      prometheus = {
        enabled = true
        serviceMonitor = {
          enabled        = var.enable_service_monitors
          namespace      = "monitoring"
          trustCRDsExist = true
        }
      }
    }

    # ── Resource requests ──
    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "512Mi"
      }
    }
  })]
}
