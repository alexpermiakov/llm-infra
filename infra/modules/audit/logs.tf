# S3 Buckets for Audit Logging
# CloudTrail logs and centralized S3 access logs

module "cloudtrail_bucket" {
  source = "../shared/compliant-s3-bucket"

  bucket_name           = "CloudTrail Logs"
  bucket_prefix         = "cloudtrail-logs"
  environment           = var.environment
  purpose               = "audit-trail"
  enable_access_logging = true
  access_logs_bucket    = module.access_logs_bucket.bucket_id
  access_logs_prefix    = "cloudtrail/"

  # PCI-DSS 10.5.2 - Protect audit trails from unauthorized modification (WORM)
  enable_object_lock         = true
  object_lock_mode           = "GOVERNANCE"
  object_lock_retention_days = 2555 # 7 years for PCI-DSS

  compliance_retention_days = 2555
  non_prod_retention_days   = 90

  lifecycle_transitions = [
    { days = 90, storage_class = "STANDARD_IA" },
    { days = 365, storage_class = "GLACIER" }
  ]
  non_prod_transitions = [
    { days = 30, storage_class = "STANDARD_IA" },
    { days = 60, storage_class = "GLACIER" }
  ]

  # CloudTrail encrypts logs at source (calls KMS GenerateDataKey), then sends
  # ciphertext to S3. Grant CloudTrail access to the bucket's KMS key.
  kms_additional_policy_statements = [
    {
      Sid    = "AllowCloudTrailEncrypt"
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action = [
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ]
      Resource = "*"
      Condition = {
        StringLike = {
          "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
        }
      }
    }
  ]

  additional_tags = {
    Compliance = "pci-dss-hipaa-sox"
    DataClass  = "audit-logs"
  }
}

# CloudTrail bucket policy - created separately to reference the actual bucket name
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = module.cloudtrail_bucket.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = module.cloudtrail_bucket.bucket_arn
        Condition = {
          StringLike = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${module.cloudtrail_bucket.bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
          StringLike = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      }
    ]
  })
}

module "access_logs_bucket" {
  source = "../shared/compliant-s3-bucket"

  bucket_name   = "Centralized S3 Access Logs"
  bucket_prefix = "s3-access-logs"
  environment   = var.environment
  purpose       = "centralized-access-logging"

  enable_object_lock = false

  compliance_retention_days = 365
  non_prod_retention_days   = 30
  lifecycle_transitions     = []
}
