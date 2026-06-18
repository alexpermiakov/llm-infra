output "bucket_id" {
  description = "The name of the bucket"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "The ARN of the bucket"
  value       = aws_s3_bucket.this.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for encryption"
  value       = module.kms_key.key_arn
}

output "kms_key_id" {
  description = "ID of the KMS key used for encryption"
  value       = module.kms_key.key_id
}

output "irsa_role_arn" {
  description = "ARN of the IRSA role (null if irsa_config not provided)"
  value       = var.irsa_config != null ? aws_iam_role.irsa[0].arn : null
}
