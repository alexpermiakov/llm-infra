# AWS Inspector scans ECR images and Lambda functions for vulnerabilities
# Required for: PCI-DSS 6.1, FDA 21 CFR Part 11, SOC 2 CC7.1

resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "LAMBDA", "EC2"]

  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}

resource "aws_inspector2_organization_configuration" "main" {
  count = var.environment == "prod" ? 1 : 0

  auto_enable {
    ec2    = true
    ecr    = true
    lambda = true
  }

  depends_on = [aws_inspector2_enabler.main]
}

resource "aws_cloudwatch_metric_alarm" "inspector_critical_findings" {
  alarm_name          = "inspector-critical-findings-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CRITICAL"
  namespace           = "AWS/Inspector2"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Critical vulnerabilities detected by Inspector"

  dimensions = {
    ResourceType = "AWS_ECR_CONTAINER_IMAGE"
  }

  alarm_actions = var.environment == "prod" ? [aws_sns_topic.security_alerts.arn] : []

  tags = {
    Environment = var.environment
    Purpose     = "vulnerability-alerting"
    Compliance  = "pci-dss"
    ManagedBy   = "Terraform"
  }
}

resource "aws_sns_topic" "security_alerts" {
  name = "security-alerts-${var.environment}"

  kms_master_key_id = "alias/aws/sns"

  tags = {
    Environment = var.environment
    Purpose     = "security-alerting"
    ManagedBy   = "Terraform"
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:alarm:*"
          }
        }
      },
      { Sid    = "AllowInspectorFindings"
        Effect = "Allow"
        Principal = {
          Service = "inspector2.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  for_each = toset(var.security_alert_emails)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_inspector2_filter" "suppress_accepted_risks" {
  name   = "suppress-accepted-risks-${var.environment}"
  action = "SUPPRESS"

  description = "Suppress findings for accepted risks documented in risk register"

  filter_criteria {
    severity {
      comparison = "EQUALS"
      value      = "INFORMATIONAL"
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_inspector2_enabler.main]
}
