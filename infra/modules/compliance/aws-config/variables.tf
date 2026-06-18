variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "include_global_resources" {
  description = "Whether to include global resources (IAM, CloudFront). Set to true in only ONE region to avoid duplicates."
  type        = bool
  default     = true
}

variable "access_logs_bucket" {
  description = "Centralized S3 bucket name for access logs"
  type        = string
  default     = ""
}

variable "ebs_default_kms_key_arn" {
  description = "KMS key ARN for default EBS encryption (only used in prod)"
  type        = string
  default     = ""
}
