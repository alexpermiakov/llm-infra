# Multi-region EKS cluster deployment

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.1"
    }
    kubectl = {
      source = "alekc/kubectl"
      # Pinned: alekc/kubectl 2.1+ eagerly validates `host` at provider-configure
      # time and rejects unknown values, breaking greenfield applies where
      # module.eks.cluster_endpoint is `(known after apply)`. 2.0.4 defers
      # validation to use, which lets fresh PR clusters bring up cleanly.
      # Revisit when a 2.x version restores deferred validation, or migrate the
      # ~15 kubectl_manifest resources to hashicorp/kubernetes_manifest.
      version = "= 2.0.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source      = "../modules/vpc"
  pr_number   = var.pr_number
  environment = var.environment
  region      = var.aws_region

  vpc_cidr_block     = var.vpc_cidr_block
  availability_zones = var.availability_zones
  subnet_cidr_blocks = var.subnet_cidr_blocks
}

module "eks" {
  source      = "../modules/eks"
  pr_number   = var.pr_number
  environment = var.environment

  enable_gpu      = true
  vpc_id          = module.vpc.vpc_id
  vpc_subnet_ids  = module.vpc.private_subnet_ids
  admin_role_arns = var.admin_role_arns
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.11.0"

  # CI self-heal: same rationale as helm_release.cilium. If a previous apply
  # left this release in `failed` state, the next install errors with
  # "cannot re-use a name that is still in use". `replace` purges the broken
  # record on install; `cleanup_on_fail` removes partial resources.
  replace         = true
  cleanup_on_fail = true

  # Use a values block so we can express tolerations as a list (set/set_list
  # don't model nested arrays cleanly). Tolerating CriticalAddonsOnly lets the
  # controller pods land on the bootstrap node immediately during greenfield
  # bring-up, instead of waiting for Karpenter to provision a regular node
  # (which can exceed Helm's 5-min wait timeout).
  values = [yamlencode({
    clusterName = module.eks.cluster_name
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.eks.aws_load_balancer_controller_irsa_role_arn
      }
    }
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" }
    ]
    # CRITICAL: disable the Service mutator webhook (mservice.elbv2.k8s.aws).
    # That webhook intercepts *every* Service CREATE cluster-wide and exists
    # only to make this controller the default for `Service type=LoadBalancer`.
    # This platform exposes everything through ALB Ingress (group.name=
    # idp-services) and has no type=LoadBalancer Services, so the webhook is
    # pure liability: its chart default is failurePolicy=Fail, so during
    # greenfield bring-up — before the controller pods have Ready endpoints —
    # it denies internal ClusterIP Service creates (kube-dns, hubble-peer,
    # addon Services), deadlocking the cluster. With no webhook, that class of
    # failure cannot occur. (Note: the chart key is serviceMutatorWebhookConfig
    # .failurePolicy, NOT webhookFailurePolicy — the latter is silently
    # ignored by Helm, which is why the earlier "Ignore" guard never worked.)
    enableServiceMutatorWebhook = false
  })]

  # Depend on the bootstrap NG, not just module.eks: after the addons/NG
  # refactor, module.eks completes before any node exists. Without this
  # dependency the controller pods would be applied against an empty cluster
  # and helm wait would hang until Karpenter caught up.
  depends_on = [aws_eks_node_group.bootstrap]
}

module "argocd" {
  source       = "../modules/argocd"
  cluster_name = module.eks.cluster_name
  region       = var.aws_region

  target_branch = var.target_branch
  environment   = var.environment
  pr_number     = var.pr_number

  # Platform values for Helm charts
  ecr_account_id = var.ecr_account_id
  waf_acl_arn    = module.waf.web_acl_arn

  depends_on = [module.eks, module.waf, helm_release.aws_load_balancer_controller]
}

module "external_secrets" {
  source       = "../modules/external-secrets"
  environment  = var.environment
  cluster_name = module.eks.cluster_name
  region       = var.aws_region

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider
  kms_key_arn       = module.argocd.kms_key_arn

  argocd_namespace_depends_on = module.argocd.namespace
  github_app_secret_name      = module.argocd.github_app_secret_name
  github_org                  = "alexpermiakov"

  depends_on = [module.eks, module.argocd]
}

module "monitoring" {
  source      = "../modules/monitoring"
  environment = var.environment

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider

  grafana_admin_password = var.grafana_admin_password

  # Centralized access logs bucket from audit module
  access_logs_bucket = var.is_primary ? module.audit[0].access_logs_bucket : ""

  depends_on = [module.eks, helm_release.aws_load_balancer_controller]
}

# module "cost" {
#   source       = "../modules/cost"
#   environment  = var.environment
#   cluster_name = module.eks.cluster_name

#   depends_on = [module.eks, module.monitoring]
# }

# module "security" {
#   source      = "../modules/security"
#   environment = var.environment

#   cluster_name             = module.eks.cluster_name
#   region                   = var.aws_region
#   oidc_provider_arn        = module.eks.oidc_provider_arn
#   oidc_provider            = module.eks.oidc_provider
#   security_logs_bucket     = var.is_primary ? module.audit[0].access_logs_bucket : ""
#   security_logs_bucket_arn = var.is_primary ? module.audit[0].access_logs_bucket_arn : ""
#   ecr_account_id           = var.ecr_account_id

#   depends_on = [module.eks, module.monitoring, module.audit, helm_release.aws_load_balancer_controller]
# }

module "argo_rollouts" {
  source            = "../modules/argo-rollouts"
  environment       = var.environment
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider

  depends_on = [module.eks, module.argocd, module.monitoring, helm_release.aws_load_balancer_controller]
}

# Phase 3: Cilium in ENI mode — Cilium owns IPAM and replaces kube-proxy.
# Installed BEFORE the bootstrap node group so a greenfield cluster can bring
# up its first node (Cilium provides the CNI binary; without it kubelet never
# registers Ready and the NG fails with NodeCreationFailure).
# See: docs/runbooks/cilium-migration.md
module "cilium" {
  source           = "../modules/cilium"
  environment      = var.environment
  vpc_cidr         = module.vpc.vpc_cidr_block
  cluster_endpoint = module.eks.cluster_endpoint

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# Bootstrap node group — lives at top level (not inside module.eks) so it can
# depend on module.cilium. Order on greenfield apply:
#   1. module.eks creates cluster (no node groups, addons in CREATING state).
#   2. module.cilium installs Cilium via Helm against the empty cluster
#      (wait=false; DS pods stay Pending until the node joins).
#   3. aws_eks_node_group.bootstrap launches the first node → cilium-agent DS
#      pod schedules (host-network, tolerates CriticalAddonsOnly), writes
#      /etc/cni/net.d/, kubelet registers Ready, addons go ACTIVE.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bootstrap_node" {
  name = "${module.eks.cluster_name}-bootstrap-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bootstrap_node_worker" {
  role       = aws_iam_role.bootstrap_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# AmazonEKS_CNI_Policy gives ec2:AssignPrivateIpAddresses / CreateNetworkInterface
# perms that Cilium ENI mode needs (operator runs on the bootstrap node and
# uses the node's instance role).
resource "aws_iam_role_policy_attachment" "bootstrap_node_cni" {
  role       = aws_iam_role.bootstrap_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "bootstrap_node_ecr" {
  role       = aws_iam_role.bootstrap_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "bootstrap_node_ssm" {
  role       = aws_iam_role.bootstrap_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Launch template attaches the shared node security group created by the eks
# module so bootstrap and Karpenter-provisioned nodes share L4 connectivity.
resource "aws_launch_template" "bootstrap_node" {
  name_prefix            = "${module.eks.cluster_name}-bootstrap-"
  vpc_security_group_ids = [module.eks.node_security_group_id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${module.eks.cluster_name}-bootstrap"
      PR   = var.pr_number
    }
  }
}

resource "aws_eks_node_group" "bootstrap" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "bootstrap"
  node_role_arn   = aws_iam_role.bootstrap_node.arn
  subnet_ids      = module.vpc.private_subnet_ids
  capacity_type   = "ON_DEMAND"
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  labels = {
    "node.kubernetes.io/purpose" = "bootstrap"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  launch_template {
    id      = aws_launch_template.bootstrap_node.id
    version = aws_launch_template.bootstrap_node.latest_version
  }

  # Critical: Cilium must be installed before this node tries to register,
  # otherwise kubelet has no CNI and the NG fails with NodeCreationFailure.
  depends_on = [
    module.cilium,
    aws_iam_role_policy_attachment.bootstrap_node_worker,
    aws_iam_role_policy_attachment.bootstrap_node_cni,
    aws_iam_role_policy_attachment.bootstrap_node_ecr,
    aws_iam_role_policy_attachment.bootstrap_node_ssm,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

# ---------------------------------------------------------------------------
# EKS managed addons. Defined here (not inside module.eks) because the
# aws_eks_addon resource waits for ACTIVE status, which for coredns /
# metrics-server / aws-ebs-csi-driver requires controller pods to be Ready.
# That requires nodes, which depend on Cilium, which depends on module.eks
# completing — so the addons can't live inside module.eks without a cycle.
# eks-pod-identity-agent runs as a DaemonSet and likewise needs at least one
# node before it can go ACTIVE.
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  addon_version               = module.eks.addon_versions["coredns"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.bootstrap]
}

resource "aws_eks_addon" "eks_pod_identity_agent" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = module.eks.addon_versions["eks-pod-identity-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.bootstrap]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "metrics-server"
  addon_version               = module.eks.addon_versions["metrics-server"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.bootstrap]
}

resource "aws_eks_addon" "aws_ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = module.eks.addon_versions["aws-ebs-csi-driver"]
  service_account_role_arn    = module.eks.ebs_csi_irsa_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.bootstrap]
}

module "audit" {
  count       = var.is_primary ? 1 : 0
  source      = "../modules/audit"
  environment = var.environment

  depends_on = [module.eks]
}

module "compliance" {
  source      = "../modules/compliance"
  environment = var.environment

  # Only include global resources (IAM, etc.) in primary region
  # to avoid duplicate recordings across regions
  include_global_resources = var.is_primary
  security_alert_emails    = var.is_primary ? var.security_alert_emails : []
  access_logs_bucket       = var.is_primary ? module.audit[0].access_logs_bucket : ""
  ebs_default_kms_key_arn  = module.eks.kms_key_arn

  depends_on = [module.eks, module.audit]
}

module "waf" {
  source      = "../modules/waf"
  environment = var.environment
  region      = var.aws_region
  pr_number   = var.pr_number
  kms_key_arn = module.eks.kms_key_arn

  depends_on = [module.eks]
}

// MSK was removed for the simplified demo setup. If you re-enable it later,
// uncomment the module block and restore the infra/modules/msk directory.

module "backup" {
  source      = "../modules/backup"
  environment = var.environment

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider

  depends_on = [module.eks, helm_release.aws_load_balancer_controller]
}
