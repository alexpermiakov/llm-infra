variable "environment" {
  description = "Environment name: dev, staging, prod, or tooling"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod", "tooling"], var.environment)
    error_message = "Environment must be dev, staging, prod, or tooling."
  }
}

variable "security_alert_emails" {
  description = "Email addresses to receive security alerts (prod only)"
  type        = list(string)
  default     = []
}
