# Creates a CloudWatch Log Group with KMS encryption, optional IAM role for AWS services,
# and S3 archival for long-term compliance storage.
# Architecture: AWS Service → CloudWatch (short-term) → Firehose → S3 (long-term)
#
# Supports two IAM modes:
#   1. service_principal: For AWS services (VPC Flow Logs, Route53, etc.)
#   2. irsa_config: For Kubernetes workloads via IRSA (Falco, Fluent Bit, etc.)

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  log_group_arn = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_path}"
  retention     = var.environment == "prod" ? var.retention_days.prod : var.retention_days.default

  # Determine if we need to create an IAM role
  create_service_role = var.service_principal != null
  create_irsa_role    = var.irsa_config != null

  common_tags = merge(var.tags, {
    Environment = var.environment
    Compliance  = "pci-dss-hipaa"
    ManagedBy   = "Terraform"
  })

  # Build IAM policy statements - always include CloudWatch, optionally add extras
  cloudwatch_statement = {
    Effect = "Allow"
    Action = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    Resource = "${aws_cloudwatch_log_group.this.arn}:*"
  }
  iam_policy_statements = concat([local.cloudwatch_statement], var.additional_iam_statements)
}

module "kms" {
  source = "../compliant-kms-key"

  name        = var.name
  description = var.kms_description
  environment = var.environment
  purpose     = "${var.name}-encryption"

  cloudwatch_log_arns = [local.log_group_arn]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = var.log_group_path
  retention_in_days = local.retention
  kms_key_id        = module.kms.key_arn

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.region}"
  })
}

resource "aws_iam_role" "service" {
  count = local.create_service_role ? 1 : 0

  name = "${var.name}-role-${var.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = var.service_principal
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name}-role-${var.region}"
  })
}

resource "aws_iam_role_policy" "service" {
  count = local.create_service_role ? 1 : 0

  name = "${var.name}-policy-${var.region}"
  role = aws_iam_role.service[0].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.iam_policy_statements
  })
}

resource "aws_iam_role" "irsa" {
  count = local.create_irsa_role ? 1 : 0

  name = "${var.name}-role-${var.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name}-role-${var.region}"
  })
}

resource "aws_iam_role_policy" "irsa" {
  count = local.create_irsa_role ? 1 : 0

  name = "${var.name}-policy-${var.region}"
  role = aws_iam_role.irsa[0].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.iam_policy_statements
  })
}

module "archival" {
  source = "../log-archival"

  name        = var.name
  environment = var.environment
  log_source  = "cloudwatch"

  log_group_names = [aws_cloudwatch_log_group.this.name]

  bucket_name   = "${var.name} Archive"
  bucket_prefix = var.archival_bucket_prefix
  purpose       = "${var.name}-compliance"
  s3_prefix     = var.archival_s3_prefix

  compliance_retention_days = var.archival_retention_days.prod
  non_prod_retention_days   = var.archival_retention_days.default

  lifecycle_transitions = var.archival_lifecycle_transitions

  buffering_size     = var.archival_buffering.size_mb
  buffering_interval = var.archival_buffering.interval_seconds
}
