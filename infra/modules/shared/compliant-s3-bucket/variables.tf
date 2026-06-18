# -----------------------------------------------------------------------------
# Required Variables
# -----------------------------------------------------------------------------

variable "bucket_name" {
  description = "Human-readable name for the bucket (used in tags)"
  type        = string
}

variable "bucket_prefix" {
  description = "Prefix for the bucket name (will be appended with environment and random suffix)"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "purpose" {
  description = "Purpose of the bucket (e.g., audit-logs, backups, loki-logs)"
  type        = string
}

# -----------------------------------------------------------------------------
# Optional Variables - Naming
# -----------------------------------------------------------------------------

variable "bucket_name_override" {
  description = "Override the generated bucket name entirely (use for buckets with specific naming requirements like WAF)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Optional Variables - Compliance & Classification
# -----------------------------------------------------------------------------

variable "compliance_frameworks" {
  description = "Compliance frameworks this bucket adheres to (for tagging)"
  type        = string
  default     = "pci-dss-hipaa"
}

variable "data_classification" {
  description = "Data classification level (public, internal, confidential, restricted)"
  type        = string
  default     = "confidential"

  validation {
    condition     = contains(["public", "internal", "confidential", "restricted"], var.data_classification)
    error_message = "Data classification must be public, internal, confidential, or restricted."
  }
}

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "kms_additional_policy_statements" {
  description = "Additional IAM policy statements for KMS key (for service access like Firehose, CloudTrail)"
  type        = list(any)
  default     = []
}

variable "enable_object_lock" {
  description = "Enable Object Lock for immutability (only applies in prod)"
  type        = bool
  default     = true
}

variable "object_lock_mode" {
  description = "Object Lock retention mode (GOVERNANCE or COMPLIANCE)"
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "Object lock mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "object_lock_retention_days" {
  description = "Number of days to retain objects under Object Lock"
  type        = number
  default     = 2555 # 7 years for SOX/HIPAA compliance
}

# -----------------------------------------------------------------------------
# Optional Variables - Lifecycle & Retention
# -----------------------------------------------------------------------------

variable "compliance_retention_days" {
  description = "Number of days to retain objects in prod (7 years = 2555 days for SOX/HIPAA)"
  type        = number
  default     = 2555
}

variable "non_prod_retention_days" {
  description = "Number of days to retain objects in non-prod environments"
  type        = number
  default     = 90
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days to retain noncurrent object versions"
  type        = number
  default     = 30
}

variable "lifecycle_transitions" {
  description = "Lifecycle transitions for prod environment"
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = [
    { days = 30, storage_class = "STANDARD_IA" },
    { days = 90, storage_class = "GLACIER" },
    { days = 365, storage_class = "DEEP_ARCHIVE" }
  ]
}

variable "non_prod_transitions" {
  description = "Lifecycle transitions for non-prod environments (empty by default for cost)"
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = []
}

variable "enable_access_logging" {
  description = "Whether to enable access logging (set to true when access_logs_bucket is provided)"
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "S3 bucket name for access logs (requires enable_access_logging = true)"
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "Prefix for access logs (defaults to purpose/)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Optional Variables - IRSA (IAM Roles for Service Accounts)
# -----------------------------------------------------------------------------

variable "irsa_config" {
  description = "IRSA configuration for Kubernetes workloads. When set, creates an IAM role with S3 and KMS access."
  type = object({
    oidc_provider_arn = string
    oidc_provider     = string
    namespace         = string
    service_account   = string
  })
  default = null
}

variable "additional_iam_statements" {
  description = "Additional IAM policy statements for the IRSA role (beyond S3 and KMS access)"
  type        = list(any)
  default     = []
}
