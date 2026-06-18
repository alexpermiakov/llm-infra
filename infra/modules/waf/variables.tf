variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "pr_number" {
  description = "PR number for dev environment isolation (0 = not a PR environment)"
  type        = number
  default     = 0
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting CloudWatch logs"
  type        = string
  default     = ""
}
