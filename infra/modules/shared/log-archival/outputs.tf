output "bucket_arn" {
  description = "ARN of the S3 bucket for log archival"
  value       = module.logs_bucket.bucket_arn
}

output "bucket_id" {
  description = "Name/ID of the S3 bucket for log archival"
  value       = module.logs_bucket.bucket_id
}

output "firehose_arn" {
  description = "ARN of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.firehose_to_s3.arn
}

output "firehose_name" {
  description = "Name of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.firehose_to_s3.name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt archived logs in S3"
  value       = module.logs_bucket.kms_key_arn
}
