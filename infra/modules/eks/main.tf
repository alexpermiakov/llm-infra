# EKS cluster with Karpenter autoscaling

terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

locals {
  cluster_name = "k8s-pr-${var.pr_number}"
  use_spot     = contains(["dev", "staging"], var.environment)
  is_prod      = var.environment == "prod"

  eks_log_group_pattern = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_name}/*"

  # Pin cluster-critical addon versions across environments to avoid managed drift
  addon_versions = {
    coredns                = "v1.13.1-eksbuild.1"
    eks-pod-identity-agent = "v1.3.10-eksbuild.2"
    metrics-server         = "v0.8.1-eksbuild.1"
    aws-ebs-csi-driver     = "v1.55.0-eksbuild.2"
  }
}

data "aws_organizations_organization" "org" {}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# PCI-DSS 3.4, 3.6: KMS key for EKS secrets and CloudWatch Logs encryption
module "eks_kms" {
  source = "../shared/compliant-kms-key"

  name        = local.cluster_name
  description = "EKS Cluster ${local.cluster_name} encryption key"
  environment = var.environment
  purpose     = "eks-encryption"

  # Allow CloudWatch Logs to encrypt/decrypt logs with this key
  cloudwatch_log_arns = [local.eks_log_group_pattern]

  additional_tags = {
    PR = tostring(var.pr_number)
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.12.0"

  name               = local.cluster_name
  kubernetes_version = "1.35"

  vpc_id     = var.vpc_id
  subnet_ids = var.vpc_subnet_ids

  # PCI-DSS 1.3: Prohibit direct public access to cardholder data environment
  endpoint_public_access                   = var.environment != "prod"
  endpoint_private_access                  = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  timeouts = {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  create_kms_key           = false
  attach_encryption_policy = true

  encryption_config = {
    provider_key_arn = module.eks_kms.key_arn
    resources        = ["secrets"]
  }

  # PCI-DSS 10.2, HIPAA §164.312(b) - Enable all control plane log types
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # PCI-DSS 3.4, 10.5: Encrypt CloudWatch control plane logs with KMS
  cloudwatch_log_group_retention_in_days = var.environment == "prod" ? 14 : 7
  cloudwatch_log_group_kms_key_id        = module.eks_kms.key_arn

  # Addons are intentionally NOT defined here. The aws_eks_addon resource waits
  # for ACTIVE status, which for coredns / metrics-server / aws-ebs-csi-driver
  # requires controller pods to be Ready. With no node group in this module,
  # those pods stay Pending and the addon hangs in CREATING (the
  # `before_compute` flag only controls Terraform DAG ordering inside this
  # module, not AWS wait behavior). Addons live in infra/entry/main.tf with
  # explicit depends_on = [aws_eks_node_group.bootstrap]. See
  # docs/runbooks/cilium-migration.md "Greenfield bootstrap" section.
  addons = {}

  # Bootstrap node group is intentionally NOT defined here. It lives in
  # infra/entry/main.tf as a top-level aws_eks_node_group.bootstrap so it can
  # depend on module.cilium (helm_release.cilium). This breaks the greenfield
  # chicken-and-egg: bootstrap NG must wait for Cilium CNI to be installed in
  # the cluster, but Cilium can install against an empty cluster (only needs
  # the API server). See docs/runbooks/cilium-migration.md “Greenfield
  # bootstrap” section.
  eks_managed_node_groups = {}

  tags = {
    Name = "k8s-cluster-pr-${var.pr_number}"
    PR   = var.pr_number
  }
}

resource "aws_iam_role_policy" "karpenter_ecr_cross_account" {
  name = "ecr-cross-account-pull"
  role = module.karpenter.node_iam_role_name

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
        Resource = "arn:aws:ecr:${data.aws_region.current.id}:*:repository/idp/*"
        Condition = {
          StringEquals = {
            "aws:ResourceOrgID" = data.aws_organizations_organization.org.id
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      }
    ]
  })

  depends_on = [module.karpenter]
}

resource "aws_eks_access_entry" "admin_roles" {
  for_each = toset(var.admin_role_arns)

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin_roles" {
  for_each = toset(var.admin_role_arns)

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin_roles]
}

# Gives the AWS Load Balancer Controller permission to manage ALBs/NLBs 
# https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts
module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.3.0"

  name = "${local.cluster_name}-aws-lbc"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = {
    PR = var.pr_number
  }
}

# Gives the EBS CSI driver permission to create/attach/delete EBS volumes
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.3.0"

  name = "${local.cluster_name}-ebs-csi"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    PR = var.pr_number
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = local.is_prod ? "Retain" : "Delete"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    fsType    = "ext4"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

# AWS-side infra for Karpenter: IAM roles, instance profile, SQS spot interruption queue
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.12.0"

  cluster_name = module.eks.cluster_name

  create_iam_role                 = true
  create_pod_identity_association = false

  iam_role_override_assume_policy_documents = [
    jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Principal = {
            Federated = module.eks.oidc_provider_arn
          }
          Action = "sts:AssumeRoleWithWebIdentity"
          Condition = {
            StringEquals = {
              "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:karpenter"
              "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            }
          }
        }
      ]
    })
  ]

  create_node_iam_role = true

  enable_spot_termination = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonECRReadOnly            = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }

  tags = {
    PR          = var.pr_number
    Environment = var.environment
  }
}

# Deploys Karpenter controller pods into the cluster, wired to the IAM role and SQS queue above
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.9.0"

  timeout = 600

  values = [
    yamlencode({
      replicas = 1
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
      # Prefer bootstrap nodes for Karpenter
      affinity = {
        nodeAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [
            {
              weight = 100
              preference = {
                matchExpressions = [
                  {
                    key      = "node.kubernetes.io/purpose"
                    operator = "In"
                    values   = ["bootstrap"]
                  }
                ]
              }
            }
          ]
        }
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
    })
  ]

  depends_on = [module.karpenter, module.eks]
}

# Phase 3 (Cilium migration) — Karpenter pool for Cilium ENI-mode nodes.
# See docs/runbooks/cilium-migration.md step 3.2.
#
# After Phase 3 step 3.2b disables the `default` pool, this is the only pool
# Karpenter can satisfy Pending pods from. Nodes provisioned here boot with no
# vpc-cni DaemonSet (addon removed in step 3.4) and Cilium ENI mode owns IPAM
# from first boot.
resource "kubectl_manifest" "karpenter_cilium_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "cilium-nodeclass"
    }
    spec = {
      role = module.karpenter.node_iam_role_name
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = module.eks.cluster_name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = module.eks.cluster_name
          }
        }
      ]
      tags = {
        PR          = tostring(var.pr_number)
        Environment = var.environment
        ManagedBy   = "karpenter"
        CNI         = "cilium"
      }
      # Cilium ENI mode with prefix delegation (see modules/cilium —
      # eni.awsEnablePrefixDelegation) lets each node hold ~110 pods. Default
      # kubelet --max-pods on AL2023 is computed from VPC-CNI's per-instance
      # ENI math (e.g. m5.large → 29), which caps Cilium far below its IP
      # capacity. Override here so kubelet matches Cilium's IP supply;
      # otherwise Karpenter spins runaway nodes that hit "Too many pods".
      kubelet = {
        maxPods = 110
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_cilium_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "cilium-nodes"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            cni = "cilium"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "cilium-nodeclass"
          }
          # Mirror the default pool's constraints so Karpenter cannot pick a
          # surprise instance type (e.g. arm64 or 16xlarge) to satisfy a small pod.
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
              values   = local.use_spot ? ["spot", "on-demand"] : ["on-demand"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["t", "m", "c"]
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = ["large", "xlarge"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"]
            },
            {
              # Prefix delegation (modules/cilium awsEnablePrefixDelegation, which
              # backs maxPods=110) only works on Nitro instances. Without this,
              # Karpenter can pick non-Nitro types (e.g. c4/m4) where it silently
              # no-ops and the node exhausts IPs at ~27 pods ("No more IPs available").
              key      = "karpenter.k8s.aws/instance-hypervisor"
              operator = "In"
              values   = ["nitro"]
            }
          ]
        }
      }
      # Match the prod CPU/memory budget from the (now-disabled) default pool.
      # Do NOT inflate this — a runaway provisioning loop here is a real cost risk.
      limits = {
        cpu    = var.environment == "prod" ? "100" : "40"
        memory = var.environment == "prod" ? "200Gi" : "80Gi"
      }
      # Karpenter v1 only accepts "WhenEmpty" or "WhenEmptyOrUnderutilized".
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_cilium_node_class]
}

module "gpu" {
  count  = var.enable_gpu ? 1 : 0
  source = "../gpu"

  cluster_name       = module.eks.cluster_name
  node_iam_role_name = module.karpenter.node_iam_role_name
  pr_number          = var.pr_number
  environment        = var.environment

  depends_on = [helm_release.karpenter]
}

module "log_archival" {
  source = "../shared/log-archival"

  name            = "k8s-audit-${local.cluster_name}"
  environment     = var.environment
  log_group_names = ["/aws/eks/${local.cluster_name}/cluster"]

  bucket_name   = "Kubernetes Audit Logs"
  bucket_prefix = "k8s-audit-logs"
  purpose       = "k8s-audit-compliance"
  s3_prefix     = "audit-logs/${local.cluster_name}"

  depends_on = [module.eks]
}
