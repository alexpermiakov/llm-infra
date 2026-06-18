variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "region" {
  description = "AWS region where the EKS cluster is deployed"
  type        = string
}

variable "target_branch" {
  description = "Git branch for ArgoCD to watch (e.g., main, feature/my-feature)"
  type        = string
  default     = "main"
}

variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "pr_number" {
  description = "Pull request number (dev environment only)"
  type        = number
  default     = 0
}

variable "ecr_account_id" {
  description = "AWS account ID where ECR repositories are hosted (tooling account)"
  type        = string
}

variable "waf_acl_arn" {
  description = "WAF ACL ARN for ingress protection"
  type        = string
  default     = ""
}

