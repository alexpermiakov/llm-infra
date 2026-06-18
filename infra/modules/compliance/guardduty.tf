# GuardDuty analyzes CloudTrail, VPC Flow Logs, and DNS logs for malicious activity
# Detects: compromised instances, credential theft, crypto mining, data exfiltration

# PCI-DSS 11.4 requires intrusion detection systems (IDS)
resource "aws_guardduty_detector" "main" {
  enable = true

  finding_publishing_frequency = var.environment == "prod" ? "FIFTEEN_MINUTES" : "ONE_HOUR"

  tags = {
    Name        = "guardduty-${var.environment}"
    Environment = var.environment
    Purpose     = "threat-detection"
    ManagedBy   = "Terraform"
  }
}

resource "aws_guardduty_detector_feature" "s3_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_audit" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_runtime" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

resource "aws_guardduty_detector_feature" "lambda" {
  detector_id = aws_guardduty_detector.main.id
  name        = "LAMBDA_NETWORK_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "malware" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}
