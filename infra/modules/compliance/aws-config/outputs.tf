output "config_bucket_arn" {
  description = "ARN of the S3 bucket storing Config snapshots"
  value       = module.config_bucket.bucket_arn
}

output "config_bucket_id" {
  description = "Name of the S3 bucket storing Config snapshots"
  value       = module.config_bucket.bucket_id
}

output "config_role_arn" {
  description = "ARN of the IAM role used by AWS Config"
  value       = aws_iam_role.config.arn
}

output "recorder_id" {
  description = "ID of the Config recorder"
  value       = aws_config_configuration_recorder.main.id
}
