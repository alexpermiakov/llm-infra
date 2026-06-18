variable "cluster_name" {
  description = "EKS cluster name — used for subnet/security-group discovery tags"
  type        = string
}

variable "node_iam_role_name" {
  description = "IAM role name attached to Karpenter-provisioned nodes (from karpenter module)"
  type        = string
}

variable "pr_number" {
  description = "Pull request number — applied as a resource tag"
  type        = number
}

variable "environment" {
  description = "Environment name (dev, staging, prod) — applied as a resource tag"
  type        = string
}
