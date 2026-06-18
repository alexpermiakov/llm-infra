# IAM Account Password Policy - PCI-DSS 8.2.3, 8.2.4, 8.2.5, HIPAA §164.308(a)(5)(ii)(D)
# IMPORTANT: This policy only affects IAM USERS with console passwords.

resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length = 14

  # PCI-DSS 8.2.3 - Password complexity requirements
  require_lowercase_characters = true
  require_uppercase_characters = true
  require_numbers              = true
  require_symbols              = true

  # PCI-DSS 8.2.4 - Password must be changed every 90 days
  max_password_age = 90

  # PCI-DSS 8.2.5 - Cannot reuse last 24 passwords
  password_reuse_prevention = 24

  allow_users_to_change_password = true

  # Don't lock accounts on expiry - allow password change at next login
  hard_expiry = false
}
