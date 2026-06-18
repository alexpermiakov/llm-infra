# GitHub App Credential Rotation

**Standard Operating Procedure (SOP)** for rotating GitHub App private keys used by ArgoCD.

> ⚠️ **Why Manual Rotation?** GitHub's API does not support programmatic private key generation.
> Unlike database passwords (auto-rotated by AWS), GitHub App keys require manual rotation
> through the GitHub UI. This is a GitHub platform limitation, not a design choice.

**Frequency:** Every 90 days (PCI-DSS 3.6.4 compliance)  
**Duration:** ~5 minutes  
**Downtime:** None (zero-downtime rotation)  
**Required Access:** GitHub Org Admin, AWS Secrets Manager write access
**Compliance:** PCI-DSS 3.6.4, HIPAA §164.312(a)(2)(iv)

---

## Overview

GitHub App private keys are rotated by updating AWS Secrets Manager. **External Secrets Operator automatically syncs the new credentials to Kubernetes within 60 seconds**, eliminating the need for manual Terraform applies or pod restarts.

---

## Procedure

### Step 1: Generate New Private Key in GitHub

1. Navigate to GitHub:

   ```
   https://github.com/organizations/YOUR_ORG/settings/apps/YOUR_APP
   ```

2. Scroll to **Private keys** section

3. Click **Generate a private key**

4. GitHub will download a `.pem` file:

   ```
   your-app-name.2026-01-17.private-key.pem
   ```

5. **Keep the old key active** until rotation is verified

---

### Step 2: Update AWS Secrets Manager

```bash
# Set values from GitHub App settings page
export GITHUB_APP_ID=  # From "App ID" field
export GITHUB_APP_INSTALLATION_ID=  # From installation URL
export GITHUB_APP_PEM_FILE=  # Path to downloaded .pem file

# Find the secret
SECRET_ARN=$(aws secretsmanager list-secrets \
  --query "SecretList[?contains(Name, 'argocd/github-app')].ARN | [0]" \
  --output text)

echo "Found: $SECRET_ARN"

# Update secret with new credentials
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ARN" \
  --secret-string "$(jq -n \
    --arg appID "$GITHUB_APP_ID" \
    --arg installationID "$GITHUB_APP_INSTALLATION_ID" \
    --rawfile privateKey "$GITHUB_APP_PEM_FILE" \
    '{appID: $appID, installationID: $installationID, privateKey: $privateKey}')" \
  --output text \
  --query 'VersionId'

echo "✅ Secret updated in AWS Secrets Manager"
```

---

### Step 3: Verify Automatic Sync (External Secrets Operator)

**Wait 60 seconds** for External Secrets Operator to sync the new credentials:

```bash
# Verify the Kubernetes secret was updated (check timestamp)
kubectl get secret github-repo-creds -n argocd -o jsonpath='{.data.githubAppInstallationID}'

```

---

### Step 4: Delete Old Key

After verifying the new key works (wait at least 5-10 minutes):

1. **Delete old private key from GitHub:**
   - Go to GitHub App settings
   - Find the old key (older date)
   - Click **Delete**

2. **Securely delete local file:**
   ```bash
   rm -P ~/Downloads/your-app-name.*.private-key.pem
   ```

---

### Step 5: Document Rotation

```bash
echo "$(date -Iseconds) | GitHub App | Rotated by $(whoami) | Auto-synced via ESO" >> docs/rotation-log.txt
```

---

