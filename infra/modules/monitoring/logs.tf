locals {
  log_retention_days = 2555
}

module "loki_logs_bucket" {
  source = "../shared/compliant-s3-bucket"

  bucket_name          = "Loki Logs"
  bucket_prefix        = "loki-logs"
  bucket_name_override = "${var.cluster_name}-loki-logs"
  environment          = var.environment
  purpose              = "loki-log-storage"
  access_logs_bucket   = var.access_logs_bucket
  access_logs_prefix   = "loki/"

  object_lock_retention_days = 365
  compliance_retention_days  = local.log_retention_days
  non_prod_retention_days    = 30

  lifecycle_transitions = [
    { days = 30, storage_class = "STANDARD_IA" },
    { days = 90, storage_class = "GLACIER" },
    { days = 365, storage_class = "DEEP_ARCHIVE" }
  ]

  # IRSA for Loki S3 access
  irsa_config = {
    oidc_provider_arn = var.oidc_provider_arn
    oidc_provider     = var.oidc_provider
    namespace         = "monitoring"
    service_account   = "loki"
  }

  additional_tags = {
    DataClass = "sensitive"
    Retention = "${local.log_retention_days} days"
  }
}
