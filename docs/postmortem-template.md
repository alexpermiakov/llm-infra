# Post-Mortem: [Incident Title]

**Date:** YYYY-MM-DD  
**Duration:** X hours Y minutes  
**Severity:** P1 / P2 / P3  
**Author:** [Your Name]  
**Status:** Draft / In Review / Complete

---

## Summary

One paragraph description of what happened, what was the impact, and how it was resolved.

---

## Impact

| Metric                | Value                    |
| --------------------- | ------------------------ |
| Duration              | X hours Y minutes        |
| Users affected        | ~N users / N% of traffic |
| Error budget consumed | X%                       |
| Revenue impact        | $X (if applicable)       |
| SLO breached          | Yes / No                 |

---

## Timeline (All times in UTC)

| Time  | Event                 |
| ----- | --------------------- |
| HH:MM | First alert fired     |
| HH:MM | On-call acknowledged  |
| HH:MM | Root cause identified |
| HH:MM | Mitigation applied    |
| HH:MM | Service restored      |
| HH:MM | All-clear declared    |

---

## Root Cause

Describe the technical root cause. Be specific.

Example: "A deployment at 14:30 UTC introduced a bug in the authentication service that caused all requests with special characters in usernames to fail with a 500 error."

---

## Detection

**How was the incident detected?**

- [ ] Automated alerting (which alert?)
- [ ] Customer report
- [ ] Internal user report
- [ ] Monitoring dashboard

**Time to Detect (TTD):** X minutes

**Was alerting adequate?** Yes / No - explain

---

## Response

**Time to Mitigate (TTM):** X minutes

**Actions taken:**

1. Action 1
2. Action 2
3. Action 3

**What went well:**

-

**What could have gone better:**

-

---

## Resolution

Describe the permanent fix (if different from mitigation).

---

## Lessons Learned

### What went well

-

### What went wrong

-

### Where we got lucky

-

---

## Action Items

| Action                     | Owner | Priority | Due Date   | Status |
| -------------------------- | ----- | -------- | ---------- | ------ |
| Add alerting for X         | @name | P1       | YYYY-MM-DD | TODO   |
| Improve runbook for Y      | @name | P2       | YYYY-MM-DD | TODO   |
| Add integration test for Z | @name | P2       | YYYY-MM-DD | TODO   |

---

## Supporting Information

### Relevant Links

- Grafana dashboard: [link]
- Alert: [link]
- Slack thread: [link]
- Related PRs: [link]

### Graphs/Screenshots

[Include relevant graphs showing the incident timeline]

---

## Five Whys Analysis

1. **Why did the outage occur?**  
   → Answer

2. **Why did [answer 1] happen?**  
   → Answer

3. **Why did [answer 2] happen?**  
   → Answer

4. **Why did [answer 3] happen?**  
   → Answer

5. **Why did [answer 4] happen?**  
   → Answer (root cause)

