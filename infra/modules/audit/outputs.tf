output "access_logs_bucket" {
  description = "S3 bucket for access logs (who accessed audit logs)"
  value       = module.access_logs_bucket.bucket_id
}

output "access_logs_bucket_arn" {
  description = "S3 bucket ARN for access logs"
  value       = module.access_logs_bucket.bucket_arn
}
