variable "name" {
  description = "Human-readable name for the KMS key (used in tags and description)"
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod). Affects deletion window."
  type        = string
}

variable "description" {
  description = "Custom description for the KMS key. If empty, auto-generated."
  type        = string
  default     = ""
}

variable "purpose" {
  description = "Purpose tag for the KMS key"
  type        = string
  default     = "encryption"
}

variable "multi_region" {
  description = "Enable multi-region key for cross-region replication scenarios"
  type        = bool
  default     = false
}

variable "cloudwatch_log_arns" {
  description = "CloudWatch Log Group ARN patterns allowed to use this key. Example: arn:aws:logs:us-east-1:123456789012:log-group:/app/*"
  type        = list(string)
  default     = []
}

variable "secrets_manager_arns" {
  description = "Secrets Manager secret ARN patterns allowed to use this key. Example: arn:aws:secretsmanager:us-east-1:123456789012:secret:app/*"
  type        = list(string)
  default     = []
}

variable "firehose_arns" {
  description = "Kinesis Firehose delivery stream ARN patterns allowed to use this key. Example: arn:aws:firehose:us-east-1:123456789012:deliverystream/logs-*"
  type        = list(string)
  default     = []
}

variable "cloudtrail_arns" {
  description = "CloudTrail trail ARN patterns allowed to use this key. Example: arn:aws:cloudtrail:*:123456789012:trail/*"
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = "S3 bucket ARN patterns allowed to use this key for encryption. Example: arn:aws:s3:::my-bucket-*"
  type        = list(string)
  default     = []
}

variable "additional_policy_statements" {
  description = "Additional IAM policy statements to add to the key policy"
  type        = list(any)
  default     = []
}

variable "additional_tags" {
  description = "Additional tags to apply to the KMS key"
  type        = map(string)
  default     = {}
}
