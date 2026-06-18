# Standards: PCI-DSS 3.4, 10.5.2, 10.7 | HIPAA §164.312 | SOX

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name            = var.bucket_name_override != "" ? var.bucket_name_override : "${var.bucket_prefix}-${var.environment}-${random_id.bucket_suffix.hex}"
  default_retention_days = var.environment == "prod" ? var.compliance_retention_days : var.non_prod_retention_days
  enable_object_lock     = var.enable_object_lock && var.environment == "prod"
}

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.environment != "prod"

  object_lock_enabled = local.enable_object_lock

  tags = merge(
    {
      Name        = var.bucket_name
      Environment = var.environment
      Purpose     = var.purpose
      Compliance  = var.compliance_frameworks
      DataClass   = var.data_classification
      ManagedBy   = "Terraform"
    },
    var.additional_tags
  )
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "kms_key" {
  source = "../compliant-kms-key"

  name                         = local.bucket_name
  environment                  = var.environment
  description                  = "KMS key for ${local.bucket_name} S3 encryption"
  purpose                      = "s3-encryption"
  s3_bucket_arns               = ["arn:aws:s3:::${local.bucket_name}"]
  additional_policy_statements = var.kms_additional_policy_statements
  additional_tags              = var.additional_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = module.kms_key.key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  count = local.enable_object_lock ? 1 : 0

  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.environment == "prod" ? [1] : []
    content {
      id     = "${var.purpose}-retention-prod"
      status = "Enabled"

      dynamic "transition" {
        for_each = var.lifecycle_transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      expiration {
        days = var.compliance_retention_days
      }

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }
  }

  dynamic "rule" {
    for_each = var.environment != "prod" ? [1] : []
    content {
      id     = "${var.purpose}-retention-nonprod"
      status = "Enabled"

      dynamic "transition" {
        for_each = var.non_prod_transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      expiration {
        days = var.non_prod_retention_days
      }

      noncurrent_version_expiration {
        noncurrent_days = 7
      }
    }
  }
}

resource "aws_s3_bucket_logging" "this" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.this.id

  target_bucket = var.access_logs_bucket
  target_prefix = var.access_logs_prefix != "" ? var.access_logs_prefix : "${var.purpose}/"
}

resource "aws_iam_role" "irsa" {
  count = var.irsa_config != null ? 1 : 0

  name = "${local.bucket_name}-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.irsa_config.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.irsa_config.oidc_provider}:sub" = "system:serviceaccount:${var.irsa_config.namespace}:${var.irsa_config.service_account}"
            "${var.irsa_config.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(
    {
      Name        = "${local.bucket_name}-irsa"
      Environment = var.environment
      Purpose     = "${var.purpose}-s3-access"
      ManagedBy   = "Terraform"
    },
    var.additional_tags
  )
}

resource "aws_iam_role_policy" "irsa" {
  count = var.irsa_config != null ? 1 : 0

  name = "s3-kms-access"
  role = aws_iam_role.irsa[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "S3Access"
          Effect = "Allow"
          Action = [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject",
            "s3:ListBucket"
          ]
          Resource = [
            aws_s3_bucket.this.arn,
            "${aws_s3_bucket.this.arn}/*"
          ]
        },
        {
          Sid    = "KMSAccess"
          Effect = "Allow"
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:GenerateDataKey*",
            "kms:DescribeKey"
          ]
          Resource = module.kms_key.key_arn
        }
      ],
      var.additional_iam_statements
    )
  })
}
