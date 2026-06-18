# Log Archival to S3 via Kinesis Firehose
# Reusable module for compliance log retention (PCI-DSS, HIPAA, SOX)

# Supports:
#   - log_source = "cloudwatch": CloudWatch → Subscription Filter → Firehose → S3
#   - log_source = "waf": Direct Firehose → S3 (WAF writes directly to Firehose)

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Service-specific Firehose naming requirements
  firehose_name_prefix = {
    cloudwatch = ""
    waf        = "aws-waf-logs-"
    # future services can be added here
  }

  uses_subscription_filter = var.log_source == "cloudwatch"
  firehose_name            = "${local.firehose_name_prefix[var.log_source]}${var.name}-${var.environment}"
}

module "logs_bucket" {
  source = "../compliant-s3-bucket"

  bucket_name   = var.bucket_name
  bucket_prefix = var.bucket_prefix
  environment   = var.environment
  purpose       = var.purpose

  compliance_retention_days = var.compliance_retention_days
  non_prod_retention_days   = var.non_prod_retention_days

  lifecycle_transitions = var.lifecycle_transitions
  non_prod_transitions  = var.non_prod_transitions

  # S3 encrypts data at rest, not Firehose. But S3 verifies the caller - 
  # Firehose is authorized to use the KMS key before encrypting on their behalf.
  kms_additional_policy_statements = [
    {
      Sid    = "AllowFirehoseEncrypt"
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
      Action   = ["kms:GenerateDataKey"]
      Resource = "*"
    }
  ]

  additional_tags = {
    Compliance = "pci-dss-hipaa-sox"
    DataClass  = "audit-logs"
  }
}

# Subscription filter: only used when log_source = "cloudwatch"
resource "aws_cloudwatch_log_subscription_filter" "cloudwatch_to_firehose" {
  for_each = local.uses_subscription_filter ? toset(var.log_group_names) : toset([])

  name            = "${var.name}-to-s3"
  log_group_name  = each.value
  filter_pattern  = var.filter_pattern
  destination_arn = aws_kinesis_firehose_delivery_stream.firehose_to_s3.arn
  role_arn        = aws_iam_role.cloudwatch_to_firehose_role[0].arn

  depends_on = [
    aws_iam_role_policy.cloudwatch_to_firehose,
    aws_kinesis_firehose_delivery_stream.firehose_to_s3
  ]
}

resource "aws_kinesis_firehose_delivery_stream" "firehose_to_s3" {
  name        = local.firehose_name
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_to_s3_role.arn
    bucket_arn = module.logs_bucket.bucket_arn

    # This format lets Athena/Spark query efficiently:
    prefix              = "${var.s3_prefix}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/${var.name}/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = var.buffering_size
    buffering_interval = var.buffering_interval

    compression_format = "GZIP"
  }

  tags = {
    Name        = "${var.name} Log Delivery Stream"
    Environment = var.environment
    Compliance  = "pci-dss-hipaa"
    ManagedBy   = "Terraform"
  }
}


# IAM for CloudWatch → Firehose: only used when log_source = "cloudwatch"
resource "aws_iam_role" "cloudwatch_to_firehose_role" {
  count = local.uses_subscription_filter ? 1 : 0
  name  = "${var.name}-cw-to-firehose-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringLike = {
          "aws:SourceArn" = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.name} CloudWatch to Firehose Role"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy" "cloudwatch_to_firehose" {
  count = local.uses_subscription_filter ? 1 : 0
  name  = "cloudwatch-firehose-access"
  role  = aws_iam_role.cloudwatch_to_firehose_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = aws_kinesis_firehose_delivery_stream.firehose_to_s3.arn
    }]
  })
}

resource "aws_iam_role" "firehose_to_s3_role" {
  name = "${var.name}-firehose-to-s3-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.name} Firehose Role"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy" "firehose_to_s3" {
  name = "firehose-s3-delivery"
  role = aws_iam_role.firehose_to_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          module.logs_bucket.bucket_arn,
          "${module.logs_bucket.bucket_arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey"]
        Resource = module.logs_bucket.kms_key_arn
      }
    ]
  })
}
