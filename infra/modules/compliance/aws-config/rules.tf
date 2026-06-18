# AWS Config Rules - Define what "compliant" means
# https://docs-prv.pcisecuritystandards.org/PCI%20DSS/Standard/PCI-DSS-v4_0_1.pdf

# S3 Rules

# PCI-DSS 3.4 - Render PAN unreadable anywhere it is stored
resource "aws_config_config_rule" "s3_encryption" {
  name        = "s3-bucket-server-side-encryption-enabled"
  description = "Checks if S3 buckets have server-side encryption enabled"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 1.3.6 - Don't expose cardholder data to the internet
resource "aws_config_config_rule" "s3_public_access" {
  name        = "s3-bucket-public-read-prohibited"
  description = "Checks if S3 buckets block public read access"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 4.1 - Use strong cryptography for transmission
resource "aws_config_config_rule" "s3_ssl" {
  name        = "s3-bucket-ssl-requests-only"
  description = "Checks if S3 bucket policies require SSL for requests"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SSL_REQUESTS_ONLY"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Encryption Rules

# PCI-DSS 3.4 - Encrypt stored data
resource "aws_config_config_rule" "ebs_encryption" {
  name        = "encrypted-volumes"
  description = "Checks if attached EBS volumes are encrypted"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::Volume"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 3.4 - Encrypt databases
resource "aws_config_config_rule" "rds_encryption" {
  name        = "rds-storage-encrypted"
  description = "Checks if RDS DB instances have storage encryption enabled"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  scope {
    compliance_resource_types = ["AWS::RDS::DBInstance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 3.4 - Encrypt sensitive data
resource "aws_config_config_rule" "eks_secrets_encrypted" {
  name        = "eks-secrets-encrypted"
  description = "Checks if EKS clusters have envelope encryption for Kubernetes secrets"

  source {
    owner             = "AWS"
    source_identifier = "EKS_SECRETS_ENCRYPTED"
  }

  scope {
    compliance_resource_types = ["AWS::EKS::Cluster"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# IAM Rules

# PCI-DSS 7.1 - Limit access to system components
resource "aws_config_config_rule" "iam_no_admin" {
  name        = "iam-policy-no-statements-with-admin-access"
  description = "Checks if IAM policies grant full '*:*' admin access"

  source {
    owner             = "AWS"
    source_identifier = "IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS"
  }

  scope {
    compliance_resource_types = ["AWS::IAM::Policy"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 2.1 - Don't use vendor-supplied defaults
resource "aws_config_config_rule" "root_no_access_keys" {
  name        = "iam-root-access-key-check"
  description = "Checks if root account has access keys (it shouldn't)"

  source {
    owner             = "AWS"
    source_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  }

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 8.3 - Multi-factor authentication
resource "aws_config_config_rule" "root_mfa" {
  name        = "root-account-mfa-enabled"
  description = "Checks if MFA is enabled for the root account"

  source {
    owner             = "AWS"
    source_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
  }

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# HIPAA §164.312(d), PCI-DSS 8.1.4 - Inactive credentials
resource "aws_config_config_rule" "iam_credentials_unused" {
  name        = "iam-user-unused-credentials-check"
  description = "Checks if IAM users have passwords or access keys unused for 90 days"

  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_UNUSED_CREDENTIALS_CHECK"
  }

  input_parameters = jsonencode({
    maxCredentialUsageAge = "90"
  })

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 8.2.4 - Password rotation
resource "aws_config_config_rule" "iam_password_policy" {
  name        = "iam-password-policy"
  description = "Checks if IAM password policy meets compliance requirements"

  source {
    owner             = "AWS"
    source_identifier = "IAM_PASSWORD_POLICY"
  }

  input_parameters = jsonencode({
    RequireUppercaseCharacters = "true"
    RequireLowercaseCharacters = "true"
    RequireSymbols             = "true"
    RequireNumbers             = "true"
    MinimumPasswordLength      = "14"
    PasswordReusePrevention    = "24"
    MaxPasswordAge             = "90"
  })

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# SOC 2 CC6.1 - Access key rotation
resource "aws_config_config_rule" "access_key_rotated" {
  name        = "access-keys-rotated"
  description = "Checks if active IAM access keys are rotated within 90 days"

  source {
    owner             = "AWS"
    source_identifier = "ACCESS_KEYS_ROTATED"
  }

  input_parameters = jsonencode({
    maxAccessKeyAge = "90"
  })

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 8.3.1, HIPAA §164.312(d) - MFA for all IAM users
resource "aws_config_config_rule" "iam_user_mfa" {
  name        = "iam-user-mfa-enabled"
  description = "Checks if MFA is enabled for all IAM users with console access"

  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_MFA_ENABLED"
  }

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Logging & Monitoring Rules

# PCI-DSS 10.1 - Implement audit trails
resource "aws_config_config_rule" "cloudtrail_enabled" {
  name        = "cloudtrail-enabled"
  description = "Checks if CloudTrail is enabled in the account"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 10.6 - Review logs for all system components
resource "aws_config_config_rule" "vpc_flow_logs" {
  name        = "vpc-flow-logs-enabled"
  description = "Checks if VPC Flow Logs are enabled"

  source {
    owner             = "AWS"
    source_identifier = "VPC_FLOW_LOGS_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::VPC"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 11.4, SOC 2 CC7.2 - Centralized threat detection
resource "aws_config_config_rule" "guardduty_enabled_centralized" {
  name        = "guardduty-enabled-centralized"
  description = "Checks if GuardDuty is enabled in all accounts and regions with centralized findings"

  source {
    owner             = "AWS"
    source_identifier = "GUARDDUTY_ENABLED_CENTRALIZED"
  }

  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Network Rules

# PCI-DSS 1.3 - Prohibit direct public access
resource "aws_config_config_rule" "no_unrestricted_ssh" {
  name        = "restricted-ssh"
  description = "Checks if security groups allow unrestricted SSH (0.0.0.0/0 on port 22)"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 1.2 - Restrict connections between untrusted networks
resource "aws_config_config_rule" "restricted_common_ports" {
  name        = "restricted-common-ports"
  description = "Checks if security groups allow unrestricted access to high-risk ports"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPort1 = "20"   # FTP data
    blockedPort2 = "21"   # FTP control
    blockedPort3 = "3389" # RDP
    blockedPort4 = "3306" # MySQL
    blockedPort5 = "5432" # PostgreSQL
  })

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# PCI-DSS 3.4 - EKS cluster endpoint should not be public
resource "aws_config_config_rule" "eks_endpoint_no_public" {
  name        = "eks-endpoint-no-public-access"
  description = "Checks if EKS cluster endpoint is not publicly accessible"

  source {
    owner             = "AWS"
    source_identifier = "EKS_ENDPOINT_NO_PUBLIC_ACCESS"
  }

  scope {
    compliance_resource_types = ["AWS::EKS::Cluster"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
