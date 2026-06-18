# SLO Budget Burn Runbook

## Alert: SLOErrorBudgetBurn

### What's happening?

Your service is consuming its error budget faster than expected. At the current rate, you may exhaust your monthly error budget before the end of the month.

**SLO Target:** 99.9% availability (43.8 minutes of downtime per month)

### Severity: Warning

This is a **warning** alert - immediate action is not required but investigation should begin.

---

## Quick Reference

| Error Budget Remaining | Action Required                     |
| ---------------------- | ----------------------------------- |
| > 50%                  | Monitor, no action needed           |
| 25-50%                 | Investigate, plan fixes             |
| < 25%                  | Prioritize fixes this sprint        |
| < 0%                   | Freeze deployments, fix immediately |

---

## Investigation Steps

### 1. Check Current Error Rate

```bash
# Get current error rate from Prometheus
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  curl -s 'localhost:9090/api/v1/query?query=sli:http_requests:success_rate_5m'

# Check error budget remaining
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  curl -s 'localhost:9090/api/v1/query?query=slo:http_requests:error_budget_remaining'
```

### 2. Identify Failing Endpoints

```bash
# Check which endpoints are failing
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  curl -s 'localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status=~"5.."}[5m])) by (service, path)'

# Top 5 error-producing endpoints
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  curl -s 'localhost:9090/api/v1/query?query=topk(5, sum(rate(http_requests_total{status=~"5.."}[5m])) by (service, path))'
```

### 3. Check Pod Health

```bash
# Look for recent restarts
kubectl get pods -n <namespace> --sort-by='.status.containerStatuses[0].restartCount'

# Check pod events
kubectl describe pod -n <namespace> <pod-name>

# Check logs for errors
kubectl logs -n <namespace> <pod-name> --tail=100 | grep -i error
```

### 4. Check Dependencies

```bash
# Check database connectivity
kubectl exec -n <namespace> <pod-name> -- curl -s localhost:8080/health

# Check external service status
# (Check status pages for AWS, third-party APIs, etc.)
```

### 5. Check Recent Changes

```bash
# Recent deployments (ArgoCD)
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Recent config changes
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

---

## Mitigation Actions

### Immediate (if budget < 25%)

1. **Rollback recent deployment** if correlated with error spike:

   ```bash
   kubectl argo rollouts undo <rollout-name> -n <namespace>
   ```

2. **Scale up replicas** if load-related:

   ```bash
   kubectl scale deployment <name> -n <namespace> --replicas=<count>
   ```

3. **Enable circuit breaker** if downstream dependency failing

### Short-term

1. Add retries with exponential backoff for flaky dependencies
2. Implement request hedging for latency-sensitive paths
3. Review and increase resource limits if OOMKilled

---

## Escalation

| Condition                               | Action                    |
| --------------------------------------- | ------------------------- |
| Budget < 10% and dropping               | Page on-call engineer     |
| Cannot identify root cause within 30min | Escalate to service owner |
| Downstream dependency issue             | Contact dependency team   |

---

## Post-Incident

After resolving, create a post-mortem if:

- Error budget dropped below 25%
- Incident lasted > 30 minutes
- Customer impact confirmed

See: [Post-Mortem Template](../postmortem-template.md)

