# Monthly Cost Estimates

_Assumes: 2 dev clusters (PR environments), 1 staging, 1 prod (us-west-2), 1 DR standby (us-east-1) = 5 EKS clusters. Platform overhead is ~80 pods per cluster (Cilium, ArgoCD, Kyverno, Falco, Prometheus, Loki, Kubecost, etc.) requiring 2 m5.large + 1 t3.large bootstrap node minimum. S3 costs assume 3+ years of accumulated logs with 7-year retention (PCI-DSS). Does not include AWS Shield Advanced ($3,000/mo)._

## Minimum (Platform Only, No App Workloads)

| **Base Infrastructure** | Cost       | Notes                                                            |
| ----------------------- | ---------- | ---------------------------------------------------------------- |
| EKS Control Plane (×5)  | $365       | $73 × 5 clusters                                                 |
| Nodes (3/cluster, spot) | $525       | 2× m5.large + 1× t3.large, ~$35/node spot                        |
| NAT Gateway (×5)        | $225       | $45 × 5 (minimal egress)                                         |
| ALB (×5)                | $110       | $22 base × 5                                                     |
| WAF (prod + staging)    | $25        | Base + managed rules                                             |
| S3 (all buckets)        | $150       | ~100GB/mo new + 4TB accumulated in Glacier/Deep Archive (3+ yrs) |
| CloudWatch Logs         | $200       | EKS audit, VPC flow, Falco (~100GB total)                        |
| KMS (15+ keys)          | $25        | EKS, S3, logs encryption per region                              |
| Secrets Manager         | $8         | ~15 secrets across clusters                                      |
| **Base Subtotal**       | **$1,633** |                                                                  |

| **Compliance Stack**     | Cost       | Notes                                                                  |
| ------------------------ | ---------- | ---------------------------------------------------------------------- |
| AWS Config (2 regions)   | $720       | 300 resources × 5 changes/day × $0.003 + 25 rules × $0.001, continuous |
| GuardDuty (2 regions)    | $450       | EKS Runtime: ~40 vCPU × $1.50 × 5 clusters + VPC/CloudTrail/S3 sources |
| Security Hub (2 regions) | $80        | CIS, FSBP, PCI-DSS standards, ~8K checks                               |
| Macie                    | $60        | Daily scans, 25% sampling, ~50GB scanned                               |
| Inspector                | $80        | ECR images (~30), Lambda, EC2 instances                                |
| CloudTrail               | $25        | Management events + S3 storage                                         |
| **Compliance Subtotal**  | **$1,415** |                                                                        |

| **TOTAL MINIMUM** | **$3,048/month** | |

---

## Medium (3 App Teams, ~15 Microservices)

_Example: 3 teams, 5 services each. 15 services × 3 replicas = 45 app pods + 80 platform = ~125 pods/cluster in prod. Traffic: 50K requests/min, 500GB logs/month, 800 tracked resources._

| **Base Infrastructure** | Cost       | Notes                                                             |
| ----------------------- | ---------- | ----------------------------------------------------------------- |
| EKS Control Plane (×5)  | $365       | Fixed                                                             |
| Nodes (scaled)          | $1,400     | Prod: 5× m5.xlarge on-demand, others spot                         |
| NAT Gateway (×5)        | $400       | ~3TB egress/month total                                           |
| ALB (×5)                | $250       | Higher LCU from traffic                                           |
| RDS (prod db.r6g.large) | $450       | Multi-AZ + read replica in DR                                     |
| WAF                     | $150       | ~50M requests/month                                               |
| S3 (all buckets)        | $350       | ~500GB/mo new + 18TB accumulated in Glacier/Deep Archive (3+ yrs) |
| CloudWatch Logs         | $500       | ~500GB ingestion + storage                                        |
| KMS (20+ keys)          | $40        | More app-specific keys                                            |
| Secrets Manager         | $25        | ~50 secrets                                                       |
| **Base Subtotal**       | **$3,930** |                                                                   |

| **Compliance Stack**     | Cost       | Notes                                                      |
| ------------------------ | ---------- | ---------------------------------------------------------- |
| AWS Config (2 regions)   | $1,400     | 800 resources × 8 changes/day × $0.003 + 25 rules × $0.001 |
| GuardDuty (2 regions)    | $800       | ~80 vCPU × $1.50 × 5 + higher VPC/S3 event volume          |
| Security Hub (2 regions) | $150       | Higher finding volume, ~15K checks                         |
| Macie                    | $200       | 100% sampling prod, ~200GB scanned                         |
| Inspector                | $180       | 60+ container images, Lambda functions                     |
| CloudTrail               | $80        | S3 data events enabled, higher volume                      |
| **Compliance Subtotal**  | **$2,810** |                                                            |

| **TOTAL MEDIUM** | **$6,740/month** | |

---

## Serious (8 App Teams, ~30 Microservices)

_Example: E-commerce platform with 8 teams (checkout, inventory, payments, users, search, recommendations, notifications, analytics). 30 services × 5 replicas = 150 app pods + 80 platform = ~230 pods in prod. Traffic: 200K requests/min, 2TB logs/month, 2000+ tracked resources, multiple RDS instances._

| **Base Infrastructure** | Cost       | Notes                                                           |
| ----------------------- | ---------- | --------------------------------------------------------------- |
| EKS Control Plane (×5)  | $365       | Fixed                                                           |
| Nodes (scaled)          | $4,000     | Prod: 10× m5.2xlarge mixed, DR: 5× standby                      |
| NAT Gateway (×5)        | $700       | ~10TB egress/month                                              |
| ALB (×5)                | $500       | High LCU from traffic volume                                    |
| RDS (3 instances)       | $1,400     | Primary + replicas, Multi-AZ                                    |
| ElastiCache             | $350       | Redis for sessions/caching                                      |
| WAF                     | $400       | ~200M requests/month + Bot Control                              |
| S3 (all buckets)        | $800       | ~2TB/mo new + 70TB accumulated in Glacier/Deep Archive (3+ yrs) |
| CloudWatch Logs         | $1,200     | ~2TB ingestion + storage                                        |
| KMS (30+ keys)          | $60        | Per-service encryption keys                                     |
| Secrets Manager         | $70        | ~140 secrets                                                    |
| **Base Subtotal**       | **$9,845** |                                                                 |

| **Compliance Stack**     | Cost       | Notes                                                        |
| ------------------------ | ---------- | ------------------------------------------------------------ |
| AWS Config (2 regions)   | $2,800     | 2000 resources × 10 changes/day × $0.003 + 25 rules × $0.001 |
| GuardDuty (2 regions)    | $1,500     | ~200 vCPU × $1.50 × 5 + high VPC Flow/S3 data event volume   |
| Security Hub (2 regions) | $300       | Thousands of findings, ~50K checks                           |
| Macie                    | $500       | Full scanning at scale, PII detection, ~1TB scanned          |
| Inspector                | $400       | 120+ images, continuous scanning                             |
| CloudTrail               | $200       | All data events, high volume                                 |
| **Compliance Subtotal**  | **$5,700** |                                                              |

| **TOTAL SERIOUS** | **$15,545/month** | |
