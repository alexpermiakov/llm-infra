output "log_group_name" {
  description = "CloudWatch Log Group name"
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "CloudWatch Log Group ARN"
  value       = aws_cloudwatch_log_group.this.arn
}

output "iam_role_arn" {
  description = "IAM Role ARN for the service/workload to write logs (null if neither service_principal nor irsa_config is set)"
  value       = var.service_principal != null ? aws_iam_role.service[0].arn : (var.irsa_config != null ? aws_iam_role.irsa[0].arn : null)
}

output "iam_role_name" {
  description = "IAM Role name (null if neither service_principal nor irsa_config is set)"
  value       = var.service_principal != null ? aws_iam_role.service[0].name : (var.irsa_config != null ? aws_iam_role.irsa[0].name : null)
}

output "kms_key_arn" {
  description = "KMS key ARN used for log encryption"
  value       = module.kms.key_arn
}

output "archival_bucket_name" {
  description = "S3 bucket name for archived logs"
  value       = module.archival.bucket_id
}

output "archival_bucket_arn" {
  description = "S3 bucket ARN for archived logs"
  value       = module.archival.bucket_arn
}
