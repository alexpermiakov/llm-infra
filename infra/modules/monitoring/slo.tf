# SLO Metrics & Alerts (Prometheus recording rules)
# See slo-dashboard.tf for Grafana visualization

resource "kubectl_manifest" "slo_rules" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "slo-rules"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/part-of" = "kube-prometheus-stack"
        "prometheus"                = "kube-prometheus-stack-prometheus"
        "role"                      = "alert-rules"
      }
    }
    spec = {
      groups = [
        {
          name = "incident-metrics"
          rules = [
            # Track when services go into degraded state (for MTTR/MTTD calculations)
            # A service is "down" when success rate drops below 99% for 1 minute
            {
              record = "service:incident:in_progress"
              expr   = <<-EOT
                (sli:http_requests:success_rate_5m < 0.99) or vector(0)
              EOT
            },
            # Count total incidents over rolling 30d window (for calculating mean times)
            {
              record = "service:incidents:count_30d"
              expr   = <<-EOT
                count_over_time((sli:http_requests:success_rate_5m < 0.99)[30d:5m]) or vector(0)
              EOT
            },
            # MTTD: Time from degradation start until alert fires
            # This uses ALERTS_FOR_STATE which tracks how long an alert has been pending
            {
              record = "slo:mttd:seconds"
              expr   = <<-EOT
                avg(ALERTS_FOR_STATE{alertname=~"SLO.*"}) or vector(0)
              EOT
            },
            # Track alert-to-resolution duration (requires external integration for full MTTR)
            # This metric shows current incident duration for active incidents
            {
              record = "slo:active_incident:duration_seconds"
              expr   = <<-EOT
                time() - (ALERTS_FOR_STATE{alertname=~"SLO.*", alertstate="firing"}) or vector(0)
              EOT
            },
            # Service availability over 30 days (for SLA reporting)
            {
              record = "slo:availability:30d"
              expr   = <<-EOT
                avg_over_time(sli:http_requests:success_rate_5m[30d]) or vector(1)
              EOT
            }
          ]
        },
        {
          name = "slo-availability"
          rules = [
            # SLI: HTTP request success rate (non-5xx responses)
            {
              record = "sli:http_requests:success_rate_5m"
              expr   = <<-EOT
                sum(rate(http_requests_total{status!~"5.."}[5m])) by (namespace, service)
                /
                sum(rate(http_requests_total[5m])) by (namespace, service)
              EOT
            },
            # SLO: 99.9% availability (0.1% error budget)
            {
              record = "slo:http_requests:availability_target"
              expr   = "0.999"
            },
            # Error budget remaining (1 = 100%, 0 = exhausted)
            {
              record = "slo:http_requests:error_budget_remaining"
              expr   = <<-EOT
                1 - (
                  (1 - sli:http_requests:success_rate_5m)
                  /
                  (1 - slo:http_requests:availability_target)
                )
              EOT
            },
            # Alert: Burning error budget too fast (will exhaust in < 2 hours)
            {
              alert = "SLOErrorBudgetBurn"
              expr  = <<-EOT
                slo:http_requests:error_budget_remaining < 0.5
                and
                sli:http_requests:success_rate_5m < 0.999
              EOT
              for   = "5m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "SLO error budget burning fast"
                description = "Service {{ $labels.namespace }}/{{ $labels.service }} has consumed >50% of error budget. Current success rate: {{ $value | humanizePercentage }}"
                runbook_url = "https://github.com/alexpermiakov/paved-road-platform/blob/main/docs/runbooks/slo-budget-burn.md"
              }
            },
            # Alert: Error budget exhausted
            {
              alert = "SLOErrorBudgetExhausted"
              expr  = "slo:http_requests:error_budget_remaining < 0"
              for   = "1m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "SLO error budget exhausted"
                description = "Service {{ $labels.namespace }}/{{ $labels.service }} has exhausted its error budget. Immediate action required."
                runbook_url = "https://github.com/alexpermiakov/paved-road-platform/blob/main/docs/runbooks/slo-budget-exhausted.md"
              }
            }
          ]
        },
        {
          name = "slo-latency"
          rules = [
            # SLI: P99 latency
            {
              record = "sli:http_request_duration:p99_5m"
              expr   = <<-EOT
                histogram_quantile(0.99,
                  sum(rate(http_request_duration_seconds_bucket[5m])) by (namespace, service, le)
                )
              EOT
            },
            # SLO: P99 latency < 500ms
            {
              record = "slo:http_request_duration:latency_target_seconds"
              expr   = "0.5"
            },
            # Alert: P99 latency exceeding target
            {
              alert = "SLOLatencyBudgetBurn"
              expr  = "sli:http_request_duration:p99_5m > slo:http_request_duration:latency_target_seconds"
              for   = "10m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "P99 latency exceeding SLO target"
                description = "Service {{ $labels.namespace }}/{{ $labels.service }} P99 latency is {{ $value | humanizeDuration }}, exceeding 500ms target."
                runbook_url = "https://github.com/alexpermiakov/paved-road-platform/blob/main/docs/runbooks/high-latency.md"
              }
            }
          ]
        },
        {
          name = "cluster-health"
          rules = [
            # Pod restart rate (potential instability indicator)
            {
              alert = "HighPodRestartRate"
              expr  = "rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 3"
              for   = "10m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Pod restarting frequently"
                description = "Pod {{ $labels.namespace }}/{{ $labels.pod }} has restarted {{ $value | humanize }} times in the last 15 minutes."
                runbook_url = "https://github.com/alexpermiakov/paved-road-platform/blob/main/docs/runbooks/pod-crash-loop.md"
              }
            },
            # Node not ready
            {
              alert = "NodeNotReady"
              expr  = "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
              for   = "5m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "Kubernetes node not ready"
                description = "Node {{ $labels.node }} has been not ready for more than 5 minutes."
                runbook_url = "https://github.com/alexpermiakov/paved-road-platform/blob/main/docs/runbooks/node-not-ready.md"
              }
            },
            # PVC nearly full
            {
              alert = "PersistentVolumeNearlyFull"
              expr  = <<-EOT
                (
                  kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes
                ) > 0.85
              EOT
              for   = "10m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Persistent volume nearly full"
                description = "PVC {{ $labels.persistentvolumeclaim }} in namespace {{ $labels.namespace }} is {{ $value | humanizePercentage }} full."
                runbook_url = "https://github.com/alexpermiakov/paved-road-platform/blob/main/docs/runbooks/pvc-full.md"
              }
            }
          ]
        }
      ]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}
