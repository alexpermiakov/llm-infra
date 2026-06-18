# Security Hub aggregates findings from GuardDuty, Config, Inspector, and third-party tools

# PCI-DSS 12.10 requires incident response procedures - Security Hub centralizes alerts
resource "aws_securityhub_account" "main" {
  enable_default_standards = false # We'll enable specific standards below
  auto_enable_controls     = true

  control_finding_generator = "SECURITY_CONTROL"
}

# Enable AWS Foundational Security Best Practices (free, good baseline)
resource "aws_securityhub_standards_subscription" "aws_foundational" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.id}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.main]
}

# Enable CIS AWS Foundations Benchmark (industry standard)
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.id}::standards/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [aws_securityhub_account.main]
}

# Enable PCI-DSS standard (only in prod to reduce noise)
resource "aws_securityhub_standards_subscription" "pci_dss" {
  count = var.environment == "prod" ? 1 : 0

  standards_arn = "arn:aws:securityhub:${data.aws_region.current.id}::standards/pci-dss/v/3.2.1"

  depends_on = [aws_securityhub_account.main]
}

# Import findings from GuardDuty
resource "aws_securityhub_product_subscription" "guardduty" {
  product_arn = "arn:aws:securityhub:${data.aws_region.current.id}::product/aws/guardduty"

  depends_on = [aws_securityhub_account.main, aws_guardduty_detector.main]
}

# EventBridge rule to capture HIGH/CRITICAL findings from Security Hub
resource "aws_cloudwatch_event_rule" "securityhub_findings" {
  name        = "securityhub-high-severity-findings-${var.environment}"
  description = "Route high severity security findings to SNS for alerting"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = {
          Label = ["CRITICAL", "HIGH"]
        }
        Workflow = {
          Status = ["NEW"]
        }
        RecordState = ["ACTIVE"]
      }
    }
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Send consolidated findings to SNS
resource "aws_cloudwatch_event_target" "securityhub_to_sns" {
  rule      = aws_cloudwatch_event_rule.securityhub_findings.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.findings[0].Severity.Label"
      title       = "$.detail.findings[0].Title"
      description = "$.detail.findings[0].Description"
      source      = "$.detail.findings[0].ProductName"
      account     = "$.detail.findings[0].AwsAccountId"
      region      = "$.detail.findings[0].Region"
      resource    = "$.detail.findings[0].Resources[0].Id"
      findingId   = "$.detail.findings[0].Id"
    }
    input_template = "\"Security Alert [<severity>] from <source> | Title: <title> | Resource: <resource> | Account: <account> | Region: <region> | Description: <description> | Finding ID: <findingId>\""
  }
}
