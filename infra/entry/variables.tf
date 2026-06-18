# Region-specific variables (set via -var-file=regions/<region>.tfvars)
variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
}

variable "vpc_cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
}

variable "subnet_cidr_blocks" {
  description = "List of subnet CIDR blocks"
  type        = list(string)
}

variable "is_primary" {
  description = "Whether this is the primary region (for DR configuration)"
  type        = bool
  default     = true
}

# Common variables
variable "pr_number" {
  description = "The pull request number"
  type        = number
}

variable "admin_role_arns" {
  description = "List of IAM role ARNs to grant admin access. Leave empty when creating locally."
  type        = list(string)
  default     = []
}

variable "target_branch" {
  description = "Git branch for ArgoCD to watch (e.g., main, feature/my-feature)"
  type        = string
  default     = "main"
}

variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "github_app_id" {
  description = "GitHub App ID for ArgoCD"
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID for ArgoCD"
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_app_private_key" {
  description = "GitHub App Private Key for ArgoCD"
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana (override in production)"
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "ecr_account_id" {
  description = "AWS account ID where ECR repositories are hosted (tooling account)"
  type        = string
  default     = ""
}

variable "security_alert_emails" {
  description = "Email addresses to receive security alerts (Inspector, Macie, GuardDuty findings)"
  type        = list(string)
  default     = []
}
