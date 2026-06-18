# S3 Bucket for Config Snapshots
# Stores configuration history and compliance snapshots

module "config_bucket" {
  source = "../../shared/compliant-s3-bucket"

  bucket_name   = "AWS Config Snapshots"
  bucket_prefix = "aws-config"
  environment   = var.environment
  purpose       = "compliance-monitoring"

  enable_access_logging = true
  access_logs_bucket    = var.access_logs_bucket
  access_logs_prefix    = "config/"

  object_lock_retention_days = 365
  compliance_retention_days  = 365
  non_prod_retention_days    = 60

  lifecycle_transitions = [
    { days = 90, storage_class = "STANDARD_IA" }
  ]
}

# AWS Config bucket policy - created separately to reference the actual bucket name
resource "aws_s3_bucket_policy" "config" {
  bucket = module.config_bucket.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = module.config_bucket.bucket_arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AWSConfigBucketExistenceCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:ListBucket"
        Resource = module.config_bucket.bucket_arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${module.config_bucket.bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}
