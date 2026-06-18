# Security Incident Response Runbook

**Compliance:** PCI-DSS 12.10, HIPAA §164.308(a)(6), SOC2 CC7.3

## Severity Classification

| Severity          | Definition                           | Response Time | Examples                                              |
| ----------------- | ------------------------------------ | ------------- | ----------------------------------------------------- |
| **P1 - Critical** | Active breach, data exfiltration     | 15 min        | GuardDuty: UnauthorizedAccess, Trojan, CryptoCurrency |
| **P2 - High**     | Attempted breach, policy violation   | 1 hour        | Falco: shell in container, WAF blocked SQLi burst     |
| **P3 - Medium**   | Suspicious activity, misconfig       | 4 hours       | Security Hub CRITICAL finding, failed auth spike      |
| **P4 - Low**      | Informational, hardening opportunity | 24 hours      | Inspector vulnerability, Config rule drift            |

## Alert Sources

| Source           | What It Detects                                      | Dashboard         |
| ---------------- | ---------------------------------------------------- | ----------------- |
| **GuardDuty**    | AWS-level threats (compromised creds, crypto mining) | Security Hub      |
| **Falco**        | Container runtime anomalies (shell, file access)     | Grafana → Falco   |
| **Security Hub** | Aggregated findings + compliance scores              | AWS Console       |
| **WAF**          | Application attacks (SQLi, XSS, bots)                | CloudWatch → WAF  |
| **CloudTrail**   | IAM/API anomalies (via metric filters)               | CloudWatch Alarms |

## Immediate Response (First 15 Minutes)

### 1. Triage & Contain

```bash
# Identify affected resources from alert
# GuardDuty finding example:
aws guardduty get-findings --detector-id <id> --finding-ids <finding-id>

# For compromised EC2/EKS node - isolate immediately:
# Option A: Modify security group to deny all
aws ec2 modify-instance-attribute --instance-id <id> \
  --groups <isolation-sg-with-no-rules>

# Option B: For EKS pod - cordon and drain node
kubectl cordon <node-name>
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

### 2. Preserve Evidence (Before Any Remediation)

```bash
# Snapshot EBS volumes for forensics
aws ec2 create-snapshot --volume-id <vol-id> \
  --description "Incident-$(date +%Y%m%d)-forensics"

# Export CloudTrail logs for timeframe
aws s3 cp s3://cloudtrail-logs-<env>/AWSLogs/<account>/ ./incident-logs/ \
  --recursive --exclude "*" --include "*2026-01-30*"

# Capture pod logs before termination
kubectl logs <pod> --all-containers > incident-pod-logs.txt
kubectl describe pod <pod> > incident-pod-describe.txt
```

### 3. Assess Blast Radius

```bash
# Check what the compromised identity accessed
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=<user-or-role> \
  --start-time 2026-01-29T00:00:00Z

# For EKS - check audit logs
kubectl logs -n kube-system -l app=kube-apiserver | grep <suspicious-user>
```

## Remediation by Incident Type

### Compromised IAM Credentials

```bash
# 1. Disable access keys immediately
aws iam update-access-key --user-name <user> --access-key-id <key> --status Inactive

# 2. Revoke all sessions for the role (if role-based)
aws iam put-role-policy --role-name <role> --policy-name DenyAll --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Deny", "Action": "*", "Resource": "*"}]
}'

# 3. Rotate credentials after investigation
aws iam create-access-key --user-name <user>
aws iam delete-access-key --user-name <user> --access-key-id <old-key>
```

### Container Compromise (Falco Alert)

```bash
# 1. Kill the pod (will respawn clean if not persistent threat)
kubectl delete pod <pod> -n <namespace>

# 2. If image is compromised - block it
kubectl patch deployment <name> -n <namespace> -p '{"spec":{"replicas":0}}'

# 3. Check if lateral movement occurred
# Look for unusual network connections via Hubble flow logs
hubble observe --pod <namespace>/<pod> --since 1h
```

### WAF Attack Surge

```bash
# 1. Check if attacks are succeeding or blocked
aws wafv2 get-sampled-requests --web-acl-arn <arn> --rule-metric-name <metric> \
  --scope REGIONAL --time-window StartTime=2026-01-30T00:00:00Z,EndTime=2026-01-30T23:59:59Z

# 2. Add aggressive rate limiting if under active attack
# Consider temporarily blocking by IP or geo
aws wafv2 update-ip-set --name BlockedIPs --scope REGIONAL \
  --addresses <attacker-ip>/32 --id <ip-set-id> --lock-token <token>
```

## Communication

| Stakeholder      | When to Notify                        | Channel                               |
| ---------------- | ------------------------------------- | ------------------------------------- |
| Security Team    | All P1/P2                             | PagerDuty + Slack #security-incidents |
| Engineering Lead | P1                                    | Phone call                            |
| Legal/Compliance | P1 with potential data breach         | Email + meeting                       |
| Customers        | Confirmed breach affecting their data | Per breach notification policy        |

## Post-Incident (Within 72 Hours)

1. **Timeline** - Document minute-by-minute what happened
2. **Root Cause** - Why did this happen? What control failed?
3. **Impact Assessment** - What data/systems were affected?
4. **Remediation Proof** - Evidence that threat is eliminated
5. **Improvements** - What changes prevent recurrence?

Use [postmortem-template.md](../postmortem-template.md) for documentation.

## Compliance Evidence Checklist

For auditors, ensure you document:

- [ ] Detection timestamp (MTTD)
- [ ] Containment timestamp (MTTC)
- [ ] Resolution timestamp (MTTR)
- [ ] Evidence preservation proof
- [ ] Root cause analysis
- [ ] Corrective actions taken
- [ ] Preventive measures implemented

---

**Escalation Contacts:**

- Security Lead: [Configure in PagerDuty]
- AWS Support: [If Enterprise Support - open severity 1 case]
- Legal: [For breach notification requirements]

