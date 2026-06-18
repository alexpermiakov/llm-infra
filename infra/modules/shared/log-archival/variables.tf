variable "name" {
  description = "Name identifier for resources (e.g., 'app-logs', 'k8s-audit')"
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
}

variable "log_source" {
  description = "Source of logs: 'cloudwatch' (via subscription filter) or service name for direct Firehose writes (e.g., 'waf')"
  type        = string
  default     = "cloudwatch"
  validation {
    condition     = contains(["cloudwatch", "waf"], var.log_source)
    error_message = "log_source must be 'cloudwatch' or 'waf'. Add new services to validation as needed."
  }
}

variable "log_group_names" {
  description = "List of CloudWatch Log Group names to archive to S3 (only used when log_source = 'cloudwatch')"
  type        = list(string)
  default     = []
}

variable "bucket_name" {
  description = "Human-readable name for the S3 bucket (used in tags)"
  type        = string
  default     = "Audit Logs"
}

variable "bucket_prefix" {
  description = "Prefix for the S3 bucket name"
  type        = string
  default     = "audit-logs"
}

variable "purpose" {
  description = "Purpose tag for the S3 bucket"
  type        = string
  default     = "audit-compliance"
}

variable "s3_prefix" {
  description = "S3 key prefix for log objects"
  type        = string
  default     = "logs"
}

variable "compliance_retention_days" {
  description = "Retention period in days for prod (HIPAA requires 6 years = 2190 days minimum)"
  type        = number
  default     = 2555 # 7 years
}

variable "non_prod_retention_days" {
  description = "Retention period in days for non-prod environments"
  type        = number
  default     = 90
}

variable "lifecycle_transitions" {
  description = "S3 lifecycle transitions for prod"
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = [
    { days = 90, storage_class = "STANDARD_IA" },
    { days = 365, storage_class = "GLACIER" }
  ]
}

variable "non_prod_transitions" {
  description = "S3 lifecycle transitions for non-prod"
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = [
    { days = 30, storage_class = "STANDARD_IA" }
  ]
}

variable "buffering_size" {
  description = "Firehose buffer size in MB (1-128)"
  type        = number
  default     = 5
}

variable "buffering_interval" {
  description = "Firehose buffer interval in seconds (60-900)"
  type        = number
  default     = 300
}

variable "filter_pattern" {
  description = "CloudWatch Logs filter pattern (empty string = all logs)"
  type        = string
  default     = ""
}
