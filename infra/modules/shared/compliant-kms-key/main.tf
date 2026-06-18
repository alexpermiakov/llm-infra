# Compliant KMS Key Module
# Standards: PCI-DSS 3.4, 3.6 | HIPAA §164.312(a)(2)(iv) | SOC2 CC6.1

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  key_alias = "alias/${var.name}-${var.environment}-${random_id.suffix.hex}"

  cloudwatch_logs_statement = length(var.cloudwatch_log_arns) > 0 ? [{
    Sid    = "AllowCloudWatchLogs"
    Effect = "Allow"
    Principal = {
      Service = "logs.${data.aws_region.current.id}.amazonaws.com"
    }
    Action = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    Resource = "*"
    Condition = {
      ArnLike = {
        "kms:EncryptionContext:aws:logs:arn" = var.cloudwatch_log_arns
      }
    }
  }] : []

  secrets_manager_statement = length(var.secrets_manager_arns) > 0 ? [{
    Sid    = "AllowSecretsManager"
    Effect = "Allow"
    Principal = {
      Service = "secretsmanager.amazonaws.com"
    }
    Action = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:CreateGrant"
    ]
    Resource = "*"
    Condition = {
      ArnLike = {
        "kms:EncryptionContext:SecretARN" = var.secrets_manager_arns
      }
    }
  }] : []


  firehose_statement = length(var.firehose_arns) > 0 ? [{
    Sid    = "AllowFirehose"
    Effect = "Allow"
    Principal = {
      Service = "firehose.amazonaws.com"
    }
    Action = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    Resource = "*"
    Condition = {
      ArnLike = {
        "kms:EncryptionContext:aws:firehose:arn" = var.firehose_arns
      }
    }
  }] : []

  cloudtrail_statement = length(var.cloudtrail_arns) > 0 ? [{
    Sid    = "AllowCloudTrail"
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
      ArnLike = {
        "kms:EncryptionContext:aws:cloudtrail:arn" = var.cloudtrail_arns
      }
    }
  }] : []

  s3_statement = length(var.s3_bucket_arns) > 0 ? [{
    Sid    = "AllowS3BucketEncryption"
    Effect = "Allow"
    Principal = {
      Service = "s3.amazonaws.com"
    }
    Action = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]
    Resource = "*"
    Condition = {
      ArnLike = {
        "aws:SourceArn" = var.s3_bucket_arns
      }
    }
  }] : []

  # Convert each statement to JSON string first, then decode - avoids type mismatch in concat
  service_statements = [
    for stmt in flatten([
      [for s in local.cloudwatch_logs_statement : jsonencode(s)],
      [for s in local.secrets_manager_statement : jsonencode(s)],
      [for s in local.firehose_statement : jsonencode(s)],
      [for s in local.cloudtrail_statement : jsonencode(s)],
      [for s in local.s3_statement : jsonencode(s)],
      [for s in var.additional_policy_statements : jsonencode(s)],
    ]) : jsondecode(stmt)
  ]
}

resource "aws_kms_key" "this" {
  description             = var.description != "" ? var.description : "KMS key for ${var.name} - ${var.environment}"
  deletion_window_in_days = var.environment == "prod" ? 30 : 7
  enable_key_rotation     = true
  multi_region            = var.multi_region

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "EnableIAMRootPermissions"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          Action   = "kms:*"
          Resource = "*"
        }
      ],
      local.service_statements
    )
  })

  tags = merge(
    {
      Name        = var.name
      Environment = var.environment
      Purpose     = var.purpose
      Compliance  = "pci-dss-hipaa"
      ManagedBy   = "Terraform"
    },
    var.additional_tags
  )
}

resource "aws_kms_alias" "this" {
  name          = local.key_alias
  target_key_id = aws_kms_key.this.key_id
}
