terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

# EC2NodeClass selects the AMI, subnets, and security groups for GPU nodes.
# Uses a larger root volume (100Gi) to accommodate CUDA drivers + model weights.
resource "kubectl_manifest" "karpenter_gpu_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      role = var.node_iam_role_name
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize = "100Gi"
            volumeType = "gp3"
            encrypted  = true
          }
        }
      ]
      tags = {
        PR          = tostring(var.pr_number)
        Environment = var.environment
        ManagedBy   = "karpenter"
        NodeType    = "gpu"
      }
    }
  })
}

# NodePool targets g5/g6 instance families (NVIDIA A10G, 24GB VRAM).
# Taint prevents non-GPU pods from landing here; only pods with the matching
# toleration (i.e. vllm-inference) will be scheduled on these nodes.
# WhenEmpty consolidation tears down idle GPU nodes after 5m to cut costs.
resource "kubectl_manifest" "karpenter_gpu_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = ["g5", "g6"]
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = ["xlarge"]
            }
          ]
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "true"
              effect = "NoSchedule"
            }
          ]
        }
      }
      limits = {
        "nvidia.com/gpu" = "4"
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "5m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_gpu_node_class]
}

# DaemonSet that runs on every GPU node. Detects physical GPUs via the NVIDIA
# driver and registers them with the Kubernetes scheduler as nvidia.com/gpu
# extended resources. Without this, the scheduler has no knowledge of GPUs.
resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = "0.17.0"
  replace    = true

  set = [
    {
      name  = "tolerations[0].key"
      value = "nvidia.com/gpu"
    },
    {
      name  = "tolerations[0].operator"
      value = "Equal"
    },
    {
      name  = "tolerations[0].value"
      value = "true"
      type  = "string"
    },
    {
      name  = "tolerations[0].effect"
      value = "NoSchedule"
    },
    {
      name  = "tolerations[1].key"
      value = "CriticalAddonsOnly"
    },
    {
      name  = "tolerations[1].operator"
      value = "Exists"
    }
  ]
}
