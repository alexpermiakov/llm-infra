variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name for Falco log group naming"
  type        = string
  default     = ""
}

variable "region" {
  description = "AWS region for Falco CloudWatch logs"
  type        = string
  default     = "us-west-2"
}

variable "eks_cluster_ready" {
  description = "Dependency marker to ensure EKS cluster is ready before deploying Falco"
  type        = any
  default     = null
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA (Falcosidekick S3/CloudWatch access)"
  type        = string
  default     = ""
}

variable "oidc_provider" {
  description = "OIDC provider URL without https:// (e.g., oidc.eks.us-west-2.amazonaws.com/id/XXXXX)"
  type        = string
  default     = ""
}

variable "security_logs_bucket" {
  description = "S3 bucket name for security logs (Falco alerts). Typically the centralized security logs bucket from audit module."
  type        = string
  default     = ""
}

variable "security_logs_bucket_arn" {
  description = "S3 bucket ARN for security logs (for IAM policy)"
  type        = string
  default     = ""
}

variable "trusted_github_org" {
  description = "GitHub organization for image signature verification (e.g., 'your-org'). Only images signed by workflows from this org will be allowed."
  type        = string
  default     = "*"
}

variable "ecr_registry" {
  description = "ECR registry URL for image verification (e.g., 123456789.dkr.ecr.us-west-2.amazonaws.com)"
  type        = string
  default     = ""
}

variable "ecr_account_id" {
  description = "AWS account ID where ECR repositories are hosted (tooling account), for Kyverno IRSA cross-account image verification"
  type        = string
  default     = ""
}

variable "cosign_public_key" {
  description = "Cosign public key (PEM format) for verifying container image signatures"
  type        = string
  default     = "*"   # Default allows any org - CHANGE THIS for production
  sensitive   = false # Public key is not sensitive
}
