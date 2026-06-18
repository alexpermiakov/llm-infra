variable "pr_number" {
  description = "The pull request number"
  type        = number
}

variable "vpc_id" {
  description = "The VPC ID where the resources will be deployed"
  type        = string
}

variable "vpc_subnet_ids" {
  description = "The subnet IDs within the VPC"
  type        = list(string)
}

variable "admin_role_arns" {
  description = "List of IAM role ARNs to grant admin access (for console visibility). Leave empty when creating locally with SSO."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment name (dev, staging, prod). KMS encryption enabled for staging/prod only."
  type        = string
  default     = "dev"
}

variable "enable_gpu" {
  description = "Enable GPU node pool and NVIDIA device plugin for LLM inference workloads (vLLM)."
  type        = bool
  default     = false
}
