# IAM Access Analyzer - Finds resources with public or cross-account access
# Alerts when resources are accessible from outside your account

# PCI-DSS 7.1 requires access control - this catches "oops it's public" mistakes
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "iam-access-analyzer-${var.environment}"
  type          = "ACCOUNT"

  tags = {
    Name        = "iam-access-analyzer-${var.environment}"
    Environment = var.environment
    Purpose     = "access-control"
    ManagedBy   = "Terraform"
  }
}
