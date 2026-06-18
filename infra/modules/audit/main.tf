# Enables CloudTrail audit logging for compliance.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "cloudtrail_suffix" {
  byte_length = 4
}

resource "aws_cloudtrail" "main" {
  name                          = "idp-audit-trail-${var.environment}-${random_id.cloudtrail_suffix.hex}"
  s3_bucket_name                = module.cloudtrail_bucket.bucket_id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  kms_key_id = module.cloudtrail_bucket.kms_key_arn

  # Log data events for S3 and Lambda (required for PCI-DSS 10.2.1, HIPAA audit)
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # S3 object-level logging for PHI/PCI data access
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3"]
    }
  }

  tags = {
    Name        = "IDP Audit Trail"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# EventBridge Rules for Security Alerts
# Terraform uses "aws_cloudwatch_event_*" naming for EventBridge resources.
# CONNECTION TO CLOUDTRAIL: CloudTrail automatically publishes management events
# to the default EventBridge bus - no explicit configuration needed.

# Root account usage - PCI-DSS 10.2.2
resource "aws_cloudwatch_event_rule" "root_account_usage" {
  name        = "root-account-usage-${var.environment}"
  description = "CRITICAL: Root account was used - PCI-DSS 10.2.2"

  event_pattern = jsonencode({
    source      = ["aws.signin"]
    detail-type = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })

  tags = {
    Environment = var.environment
    Compliance  = "pci-dss"
    Severity    = "critical"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "root_account_usage" {
  rule      = aws_cloudwatch_event_rule.root_account_usage.name
  target_id = "send-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# Security group changes - PCI-DSS 10.2.6
resource "aws_cloudwatch_event_rule" "security_group_changes" {
  name        = "security-group-changes-${var.environment}"
  description = "Security group configuration changed - PCI-DSS 10.2.6"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName = [
        "AuthorizeSecurityGroupIngress",
        "AuthorizeSecurityGroupEgress",
        "RevokeSecurityGroupIngress",
        "RevokeSecurityGroupEgress",
        "CreateSecurityGroup",
        "DeleteSecurityGroup"
      ]
    }
  })

  tags = {
    Environment = var.environment
    Compliance  = "pci-dss"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "security_group_changes" {
  rule      = aws_cloudwatch_event_rule.security_group_changes.name
  target_id = "send-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# IAM policy changes - PCI-DSS 10.2.7
resource "aws_cloudwatch_event_rule" "iam_policy_changes" {
  name        = "iam-policy-changes-${var.environment}"
  description = "IAM policy changed - PCI-DSS 10.2.7"

  event_pattern = jsonencode({
    source      = ["aws.iam"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName = [
        "CreatePolicy",
        "DeletePolicy",
        "CreatePolicyVersion",
        "DeletePolicyVersion",
        "AttachRolePolicy",
        "DetachRolePolicy",
        "AttachUserPolicy",
        "DetachUserPolicy",
        "AttachGroupPolicy",
        "DetachGroupPolicy",
        "PutRolePolicy",
        "PutUserPolicy",
        "PutGroupPolicy",
        "DeleteRolePolicy",
        "DeleteUserPolicy",
        "DeleteGroupPolicy"
      ]
    }
  })

  tags = {
    Environment = var.environment
    Compliance  = "pci-dss"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "iam_policy_changes" {
  rule      = aws_cloudwatch_event_rule.iam_policy_changes.name
  target_id = "send-to-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublishToSNS"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "security_alert_emails" {
  for_each = toset(var.security_alert_emails)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic" "security_alerts" {
  name              = "cloudtrail-security-alerts-${var.environment}"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Environment = var.environment
    Purpose     = "security-alerting"
    ManagedBy   = "Terraform"
  }
}
