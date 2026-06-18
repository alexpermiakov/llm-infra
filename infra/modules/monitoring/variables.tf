variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
  default     = ""
}

variable "oidc_provider" {
  description = "OIDC provider URL without https://"
  type        = string
  default     = ""
}

variable "grafana_admin_password" {
  description = "Admin password for Grafana"
  type        = string
  sensitive   = true
  default     = "admin" # TODO: Override in production!
}

variable "grafana_root_url" {
  description = "Root URL for Grafana (used for links in alerts, etc.)"
  type        = string
  default     = "http://localhost:3000"
}

variable "access_logs_bucket" {
  description = "Centralized S3 bucket name for access logs (from audit module)"
  type        = string
  default     = ""
}

variable "security_alert_sns_topic_arn" {
  description = "SNS topic ARN for security alerts (DLP findings, critical events)"
  type        = string
  default     = ""
}
