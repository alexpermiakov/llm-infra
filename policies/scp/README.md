# Service Control Policies (SCPs)

Service Control Policies are organization-level guardrails that apply to ALL accounts and ALL users/roles within those accounts - including admins. Unlike IAM policies which grant permissions, SCPs set the maximum available permissions.

## Why SCPs Matter for Compliance

| Compliance        | Requirement           | SCP Control                          |
| ----------------- | --------------------- | ------------------------------------ |
| SOC2 CC5.2        | Segregation of duties | Prevents disabling security controls |
| PCI-DSS 10.5.2    | Protect audit trail   | Denies CloudTrail/Config tampering   |
| HIPAA §164.312(b) | Audit controls        | Prevents log deletion                |
| SOC2 CC6.1        | Logical access        | Enforces MFA for IAM changes         |

## Included SCPs

### 1. `deny-security-service-disruption.json`

Prevents anyone from disabling critical security services:

- GuardDuty (threat detection)
- CloudTrail (audit logging)
- AWS Config (compliance monitoring)
- Security Hub (security posture)
- Access Analyzer (IAM analysis)
- Macie (PII/PHI detection)
- Inspector (vulnerability scanning)

### 2. `deny-root-account-actions.json`

- Blocks all root user actions (root should only be used for account recovery)
- Requires MFA for IAM policy changes
- Prevents root access key creation

### 3. `require-encryption-and-deny-public-access.json`

- Denies creating unencrypted RDS instances
- Denies creating unencrypted EBS volumes
- Denies uploading unencrypted S3 objects
- Denies making RDS instances publicly accessible
- Protects S3 public access block settings

### 4. `protect-critical-resources.json`

- Denies leaving the AWS Organization
- Protects KMS keys from deletion
- Prevents disabling EBS encryption by default
- Protects VPC Flow Logs from deletion
- Protects AWS Backup vault configurations

## How to Apply SCPs

SCPs are applied via AWS Organizations. You can apply them via:

### AWS Console

1. Go to AWS Organizations → Policies → Service control policies
2. Create policy from JSON file
3. Attach to the appropriate OU (Organizational Unit)

### Terraform (recommended)

```hcl
resource "aws_organizations_policy" "deny_security_disruption" {
  name        = "DenySecurityServiceDisruption"
  description = "Prevents disabling security monitoring services"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/../../policies/scp/deny-security-service-disruption.json")
}

resource "aws_organizations_policy_attachment" "deny_security_disruption" {
  policy_id = aws_organizations_policy.deny_security_disruption.id
  target_id = aws_organizations_organizational_unit.workloads.id
}
```

### AWS CLI

```bash
# Create the policy
aws organizations create-policy \
  --name "DenySecurityServiceDisruption" \
  --type SERVICE_CONTROL_POLICY \
  --description "Prevents disabling security monitoring services" \
  --content file://policies/scp/deny-security-service-disruption.json

# Attach to OU
aws organizations attach-policy \
  --policy-id p-xxxxxxxxxx \
  --target-id ou-xxxx-xxxxxxxx
```

## Exception Handling

All SCPs include conditions to allow the `OrganizationAccountAccessRole` and `AWSControlTowerExecution` roles to perform these actions when necessary. This ensures:

- Organization admins can still make changes in emergencies
- Control Tower automation continues to work
- Break-glass procedures remain available

## Testing SCPs

Before applying to production OUs:

1. Create a test OU with a sandbox account
2. Apply SCPs to the test OU
3. Verify normal operations still work
4. Verify restricted operations are blocked
5. Graduate to production OUs

