variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the service (e.g., api.example.com)"
  type        = string
}

variable "primary_alb_dns_name" {
  description = "DNS name of the primary region ALB"
  type        = string
}

variable "primary_alb_zone_id" {
  description = "Hosted zone ID of the primary region ALB"
  type        = string
}

variable "secondary_alb_dns_name" {
  description = "DNS name of the secondary region ALB"
  type        = string
}

variable "secondary_alb_zone_id" {
  description = "Hosted zone ID of the secondary region ALB"
  type        = string
}

variable "health_check_path" {
  description = "Path for health check endpoint"
  type        = string
  default     = "/health"
}

variable "environment" {
  description = "Environment name"
  type        = string
}
