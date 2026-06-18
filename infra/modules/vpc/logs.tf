# VPC Flow Logs
# Captures network traffic metadata for security monitoring and compliance

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.idp_vpc.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = module.vpc_flow_logs.log_group_arn
  iam_role_arn             = module.vpc_flow_logs.iam_role_arn
  max_aggregation_interval = 60

  tags = {
    Name        = "vpc-flow-log-pr-${var.pr_number}-${var.region}"
    Environment = var.environment
  }
}

module "vpc_flow_logs" {
  source = "../shared/compliant-log-group"

  name              = "vpc-flow-logs-pr-${var.pr_number}"
  environment       = var.environment
  region            = var.region
  log_group_path    = "/vpc/flow-logs/pr-${var.pr_number}"
  service_principal = "vpc-flow-logs.amazonaws.com"

  kms_description = "VPC Flow Logs encryption key"

  # Short retention in CloudWatch - long-term storage is in S3
  retention_days = {
    prod    = 14
    default = 7
  }

  # S3 archival for compliance (7 years prod, 90 days non-prod)
  archival_bucket_prefix = "vpc-flow-logs-pr-${var.pr_number}-${var.region}"
  archival_s3_prefix     = "flow-logs"
}
