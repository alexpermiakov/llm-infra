variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "enable_aws_config" {
  description = "Enable AWS Config for continuous compliance monitoring. Set to false to disable (e.g., for cost savings in dev)."
  type        = bool
  default     = false
}

variable "include_global_resources" {
  description = "Whether to include global resources (IAM, CloudFront). Set to true in only ONE region to avoid duplicates."
  type        = bool
  default     = true
}

variable "security_alert_emails" {
  description = "Email addresses to receive security alerts (Inspector findings, Macie PII detection)"
  type        = list(string)
  default     = []
}

variable "access_logs_bucket" {
  description = "Centralized S3 bucket name for access logs (from audit module)"
  type        = string
  default     = ""
}

variable "ebs_default_kms_key_arn" {
  description = "KMS key ARN for default EBS encryption (only used in prod)"
  type        = string
  default     = ""
}
