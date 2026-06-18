# Compliance Module
# Orchestrates AWS compliance services: Config, GuardDuty, SecurityHub, Inspector, Macie

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "aws_config" {
  count  = var.enable_aws_config ? 1 : 0
  source = "./aws-config"

  environment              = var.environment
  include_global_resources = var.include_global_resources
  access_logs_bucket       = var.access_logs_bucket
  ebs_default_kms_key_arn  = var.ebs_default_kms_key_arn
}
