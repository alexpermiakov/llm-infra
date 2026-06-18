# AWS Macie discovers and protects sensitive data (PII/PHI) in S3
# Required for: HIPAA §164.312(d), PCI-DSS 3.4, GDPR Article 32

resource "aws_macie2_account" "main" {
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}

# Scans for PII, PHI, PCI data patterns
resource "aws_macie2_classification_job" "sensitive_data_discovery" {
  count       = var.enable_aws_config ? 1 : 0
  name        = "pii-phi-scan-${var.environment}"
  description = "Discovers PII/PHI/PCI data in S3 buckets for compliance"

  lifecycle {
    # Macie jobs can't be modified in-place; ignore name drift to prevent conflicts
    ignore_changes = [name]
  }

  job_type = "SCHEDULED"

  schedule_frequency {
    daily_schedule = true
  }

  s3_job_definition {
    bucket_definitions {
      account_id = data.aws_caller_identity.current.account_id
      buckets    = [module.aws_config[0].config_bucket_id]
    }

    scoping {
      excludes {
        and {
          simple_scope_term {
            comparator = "STARTS_WITH"
            key        = "OBJECT_KEY"
            values = [
              "AWSLogs/",
              "aws-logs/",
              "cloudtrail/",
              "config/",
              "elasticloadbalancing/",
              "vpcflowlogs/",
              "WAFLogs/"
            ]
          }
        }
        and {
          simple_scope_term {
            comparator = "EQ"
            key        = "OBJECT_EXTENSION"
            values = [
              "log",
              "gz",
              "zip",
              "tfstate"
            ]
          }
        }
        and {
          simple_scope_term {
            comparator = "STARTS_WITH"
            key        = "OBJECT_KEY"
            values = [
              "metrics/",
              "prometheus/",
              "loki/",
              "index_",
              "chunks/"
            ]
          }
        }
      }

      includes {
        and {
          simple_scope_term {
            comparator = "STARTS_WITH"
            key        = "OBJECT_KEY"
            values = [
              "data/",
              "uploads/",
              "documents/",
              "records/",
              "exports/",
              "reports/",
              "customer/",
              "patient/",
              "billing/"
            ]
          }
        }
      }
    }
  }

  sampling_percentage = var.environment == "prod" ? 100 : 25

  tags = {
    Environment = var.environment
    Purpose     = "pii-phi-discovery"
    Compliance  = "hipaa-pci-dss"
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_macie2_account.main]
}

# Custom data identifier for internal employee IDs
resource "aws_macie2_custom_data_identifier" "employee_id" {
  name        = "employee-id-${var.environment}"
  description = "Detects internal employee ID patterns"

  # Pattern: EMP-XXXXXX
  regex = "EMP-[0-9]{6}"

  keywords = ["employee", "emp_id", "staff_id", "worker"]

  maximum_match_distance = 50

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_macie2_account.main]
}

# Custom data identifier for medical record numbers
resource "aws_macie2_custom_data_identifier" "mrn" {
  name        = "medical-record-number-${var.environment}"
  description = "Detects Medical Record Number patterns (HIPAA PHI)"

  # Common MRN patterns
  regex = "MRN[:\\-]?\\s?[0-9]{7,10}"

  keywords = ["medical record", "mrn", "patient id", "chart number"]

  maximum_match_distance = 50

  tags = {
    Environment = var.environment
    Compliance  = "hipaa"
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_macie2_account.main]
}
