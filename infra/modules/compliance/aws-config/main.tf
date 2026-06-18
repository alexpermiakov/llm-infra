# AWS Config - Continuous compliance monitoring
# Records resource configurations and evaluates them against rules.
# PCI-DSS 10.2, 11.5 - Configuration monitoring and file integrity
# HIPAA §164.312(b) - Audit controls

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "config" {
  name = "aws-config-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "config.amazonaws.com"
      }
    }]
  })

  tags = {
    Name        = "AWS Config Role"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  name = "config-s3-delivery"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ]
      Resource = "${module.config_bucket.bucket_arn}/*"
      Condition = {
        StringLike = {
          "s3:x-amz-acl" = "bucket-owner-full-control"
        }
      }
    }]
  })
}

resource "aws_config_configuration_recorder" "main" {
  name     = "config-recorder-${var.environment}"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.include_global_resources
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "config-delivery-${var.environment}"
  s3_bucket_name = module.config_bucket.bucket_id

  # we record continuously (see recording_group above), 
  # but we send to s3 every 6 hours in prod, and every 24 hours in non-prod
  snapshot_delivery_properties {
    delivery_frequency = var.environment == "prod" ? "Six_Hours" : "TwentyFour_Hours"
  }

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.config
  ]
}

# Enable the configuration recorder after the delivery channel is set up
# without it, Config is defined but not running.
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# 
resource "aws_config_configuration_aggregator" "account" {
  count = var.environment == "prod" && var.include_global_resources ? 1 : 0

  name = "account-config-aggregator"

  account_aggregation_source {
    account_ids = [data.aws_caller_identity.current.account_id]
    all_regions = true
  }

  tags = {
    Name        = "Account Config Aggregator"
    Environment = var.environment
    Compliance  = "pci-dss-soc2"
    Purpose     = "centralized-compliance-monitoring"
    ManagedBy   = "Terraform"
  }
}

resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}

resource "aws_ebs_default_kms_key" "default" {
  key_arn = var.ebs_default_kms_key_arn
}
