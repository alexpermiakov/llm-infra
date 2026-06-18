# Security Module Logs
# Falco runtime security alerts → CloudWatch → S3
# Required for: SOC 2 CC6.1 (access controls), PCI-DSS 10.2 (audit trails), HIPAA §164.312(b)
module "falco_logs" {
  source = "../shared/compliant-log-group"

  name           = "falco-${var.cluster_name}"
  environment    = var.environment
  region         = var.region
  log_group_path = "/eks/falco/${var.cluster_name}"

  kms_description = "Falco CloudWatch Logs encryption key"

  # Short retention in CloudWatch - long-term storage is in S3
  retention_days = {
    prod    = 14
    default = 7
  }

  # IRSA for Falcosidekick (Kubernetes service account)
  irsa_config = {
    oidc_provider_arn = var.oidc_provider_arn
    oidc_provider     = var.oidc_provider
    namespace         = "falco-system"
    service_account   = "falco-falcosidekick"
  }

  # Additional permissions for S3 (Falcosidekick writes alerts to S3 too)
  additional_iam_statements = [
    {
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetBucketLocation"
      ]
      Resource = [
        var.security_logs_bucket_arn,
        "${var.security_logs_bucket_arn}/falco/*"
      ]
    }
  ]

  # S3 archival for compliance
  archival_bucket_prefix = "falco-logs-${var.cluster_name}"
  archival_s3_prefix     = "security-alerts"

  tags = {
    Purpose    = "runtime-security-fim"
    Compliance = "soc2-pci-hipaa"
  }
}

# NOTE: Kyverno admission decisions are captured in EKS control plane audit logs
# No separate CloudWatch log group needed for Kyverno.
