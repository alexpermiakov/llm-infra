variable "name" {
  description = "Name identifier for resources (e.g., 'vpc-flow-logs', 'eks-audit')"
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "log_group_path" {
  description = "CloudWatch Log Group path (e.g., '/vpc/flow-logs/pr-123')"
  type        = string
}

variable "service_principal" {
  description = "AWS service principal that writes to this log group (e.g., 'vpc-flow-logs.amazonaws.com'). Mutually exclusive with irsa_config."
  type        = string
  default     = null
}

variable "irsa_config" {
  description = "IRSA (IAM Roles for Service Accounts) configuration for Kubernetes workloads. Mutually exclusive with service_principal."
  type = object({
    oidc_provider_arn = string # e.g., arn:aws:iam::123456789:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXX
    oidc_provider     = string # e.g., oidc.eks.us-east-1.amazonaws.com/id/XXXXX (without https://)
    namespace         = string # e.g., falco-system
    service_account   = string # e.g., falco-falcosidekick
  })
  default = null
}

variable "additional_iam_statements" {
  description = "Additional IAM policy statements for the role (e.g., S3 access for Falcosidekick)"
  type = list(object({
    Effect   = string
    Action   = list(string)
    Resource = list(string)
  }))
  default = []
}

variable "retention_days" {
  description = "CloudWatch Log Group retention in days. Keep short - long-term storage is in S3."
  type = object({
    prod    = number
    default = number
  })
  default = {
    prod    = 14
    default = 7
  }
}

variable "kms_description" {
  description = "Description for the KMS key"
  type        = string
  default     = "CloudWatch Logs encryption key"
}

variable "archival_bucket_prefix" {
  description = "S3 bucket name prefix for archived logs"
  type        = string
}

variable "archival_s3_prefix" {
  description = "S3 key prefix for log objects"
  type        = string
  default     = "logs"
}

variable "archival_retention_days" {
  description = "S3 retention in days for compliance"
  type = object({
    prod    = number
    default = number
  })
  default = {
    prod    = 2555 # 7 years for PCI-DSS, HIPAA
    default = 90
  }
}

variable "archival_lifecycle_transitions" {
  description = "S3 lifecycle transitions to cheaper storage tiers"
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = [
    { days = 30, storage_class = "STANDARD_IA" },
    { days = 90, storage_class = "GLACIER" }
  ]
}

variable "archival_buffering" {
  description = "Firehose buffering settings"
  type = object({
    size_mb          = number
    interval_seconds = number
  })
  default = {
    size_mb          = 5
    interval_seconds = 300
  }
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
