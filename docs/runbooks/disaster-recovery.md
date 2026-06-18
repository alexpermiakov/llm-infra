# Disaster Recovery Failover Runbook

## Overview

This runbook covers failover procedures between the primary region (us-west-2) and secondary region (us-east-1).

**Architecture:** Active-Passive  
**RTO Target:** < 5 minutes  
**RPO Target:** Near-zero (GitOps - both regions sync from same Git repo)

---

## Automatic Failover (Route 53 Health Checks)

Failover is **automatic** when:

1. Route 53 health check fails 3 consecutive times (90 seconds)
2. Route 53 marks primary as unhealthy
3. DNS queries return secondary ALB IP
4. Clients reconnect to secondary region

**You don't need to do anything** - just monitor and investigate root cause.

### Verify Failover Occurred

```bash
# Check current DNS resolution
dig api.example.com +short

# Check Route 53 health check status
aws route53 get-health-check-status --health-check-id <health-check-id>

# Check CloudWatch alarm
aws cloudwatch describe-alarms --alarm-names "route53-primary-unhealthy-prod"
```

---

## Manual Failover (Planned Maintenance)

For planned maintenance on the primary region:

### Step 1: Verify Secondary is Healthy

```bash
# Connect to secondary cluster
aws eks update-kubeconfig --name k8s-pr-XXX --region us-east-1

# Check all pods are running
kubectl get pods -A | grep -v Running

# Check ArgoCD sync status
kubectl get applications -n argocd

# Test health endpoint directly
curl -k https://<secondary-alb-dns>/health
```

### Step 2: Force Failover via Route 53

```bash
# Option A: Disable health check (forces failover)
aws route53 update-health-check \
  --health-check-id <primary-health-check-id> \
  --disabled

# Option B: Update DNS record weight to 0 (if using weighted routing)
# This is cleaner for planned maintenance
```

### Step 3: Verify Traffic Shifted

```bash
# Wait for DNS TTL (usually 60 seconds)
sleep 60

# Verify DNS now returns secondary
dig api.example.com +short

# Monitor secondary cluster traffic
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -f
```

### Step 4: Perform Maintenance on Primary

```bash
# Now safe to perform maintenance on us-west-2
```

### Step 5: Restore Primary

```bash
# Re-enable health check
aws route53 update-health-check \
  --health-check-id <primary-health-check-id> \
  --no-disabled

# Verify health check passes
aws route53 get-health-check-status --health-check-id <primary-health-check-id>

# Traffic will automatically return to primary once healthy
```

---

## Failback Procedure

After an unplanned failover, once primary is fixed:

### Step 1: Fix Primary Region Issue

Document the root cause and fix it.

### Step 2: Verify Primary is Healthy

```bash
# Connect to primary cluster
aws eks update-kubeconfig --name k8s-pr-XXX --region us-west-2

# Check all pods are running
kubectl get pods -A | grep -v Running

# Check ArgoCD has synced
kubectl get applications -n argocd

# Verify health endpoint
curl -k https://<primary-alb-dns>/health
```

### Step 3: Route 53 Auto-Failback

Once primary health checks pass:

1. Route 53 marks primary as healthy
2. DNS queries return primary ALB IP
3. Traffic shifts back automatically

**Note:** There's no "sticky" session - traffic moves to healthy primary immediately.

### Step 4: Verify Failback

```bash
dig api.example.com +short
# Should return primary ALB IP
```

---

## What Gets Replicated

| Component          | Replication Method               | Lag      |
| ------------------ | -------------------------------- | -------- |
| Container images   | ECR cross-region replication     | ~seconds |
| Application config | Git (ArgoCD syncs independently) | ~seconds |
| Kubernetes state   | None (rebuilt from Git)          | N/A      |
| Prometheus metrics | None (per-region)                | N/A      |
| Grafana dashboards | ConfigMaps from Git              | ~seconds |

---

## What Does NOT Replicate

| Component                    | Impact                  | Mitigation                                  |
| ---------------------------- | ----------------------- | ------------------------------------------- |
| In-flight requests           | Dropped during failover | Client retry logic                          |
| Active WebSocket connections | Disconnected            | Client reconnect logic                      |
| Prometheus historical data   | Lost in that region     | Use Thanos/Cortex for long-term storage     |
| User sessions                | If stored in-memory     | Use external session store (Redis/DynamoDB) |

---

## Monitoring

### CloudWatch Alarms to Watch

| Alarm                              | Meaning                                     |
| ---------------------------------- | ------------------------------------------- |
| `route53-primary-unhealthy-prod`   | Primary health check failing                |
| `route53-secondary-unhealthy-prod` | Secondary also failing (both regions down!) |

### Grafana Dashboards

- **SLO Dashboard** - Check error budget burn rate post-failover
- **Cluster Dashboard** - Verify secondary is handling load

---

## Escalation

| Condition                         | Action                                          |
| --------------------------------- | ----------------------------------------------- |
| Automatic failover occurred       | Investigate primary, no immediate action needed |
| Both regions unhealthy            | **P1 INCIDENT** - All hands on deck             |
| Failback not happening            | Check primary health check, verify ALB health   |
| Data inconsistency after failover | Check ArgoCD sync status in both regions        |

---

## Post-Incident

After any failover event:

1. Create post-mortem using [template](../postmortem-template.md)
2. Document root cause
3. Update this runbook if procedures changed
4. Review RTO/RPO - did we meet targets?
