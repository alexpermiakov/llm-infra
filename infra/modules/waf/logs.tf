# WAF Logging
# Security event logs for blocked requests, rate limiting, and bot detection

module "waf_log_archival" {
  source = "../shared/log-archival"

  name        = "idp-${local.resource_suffix}-${var.region}"
  environment = var.environment
  log_source  = "waf"

  bucket_name   = "WAF Logs"
  bucket_prefix = "waf-logs"
  purpose       = "waf-security-logs"
  s3_prefix     = "waf-logs"

  compliance_retention_days = 2555
  non_prod_retention_days   = 365

  lifecycle_transitions = [
    { days = 30, storage_class = "STANDARD_IA" },
    { days = 90, storage_class = "GLACIER" }
  ]
}

# Configure WAF to log to Firehose
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [module.waf_log_archival.firehose_arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior = "KEEP"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
      requirement = "MEETS_ANY"
    }
  }
}
