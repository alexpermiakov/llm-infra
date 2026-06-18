# Check https://kyverno.io/docs/monitoring/admission-review-latency/
# for metrics details and recommended Prometheus queries.

resource "kubernetes_config_map_v1" "kyverno_dashboard" {
  metadata {
    name      = "grafana-dashboard-kyverno"
    namespace = var.namespace
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "Security"
    }
  }

  data = {
    "kyverno-policies.json" = jsonencode({
      annotations = {
        list = []
      }
      editable             = true
      fiscalYearStartMonth = 0
      graphTooltip         = 0
      id                   = null
      links                = []
      liveNow              = false
      panels = [
        {
          id        = 1
          type      = "row"
          title     = "Policy Overview"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 0 }
        },
        {
          id      = 2
          type    = "stat"
          title   = "Total Policies"
          gridPos = { h = 4, w = 4, x = 0, y = 1 }
          targets = [
            {
              expr         = "count(count by (policy_name) (kyverno_policy_rule_info_total))"
              legendFormat = "Policies"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "auto"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "blue", value = null }
                ]
              }
            }
          }
        },
        {
          id      = 3
          type    = "stat"
          title   = "Policy Violations (Audit)"
          gridPos = { h = 4, w = 4, x = 4, y = 1 }
          targets = [
            {
              expr         = "sum(increase(kyverno_policy_results{rule_result=\"fail\"}[24h])) or vector(0)"
              legendFormat = "Violations"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "auto"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 1 },
                  { color = "red", value = 10 }
                ]
              }
            }
          }
        },
        {
          id      = 4
          type    = "stat"
          title   = "Admission Requests Blocked"
          gridPos = { h = 4, w = 4, x = 8, y = 1 }
          targets = [
            {
              expr         = "sum(kyverno_admission_requests_total{request_allowed='false'}) or vector(0)"
              legendFormat = "Blocked"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "auto"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "orange", value = 1 }
                ]
              }
            }
          }
        },
        {
          id      = 5
          type    = "stat"
          title   = "Admission Latency (p99)"
          gridPos = { h = 4, w = 4, x = 12, y = 1 }
          targets = [
            {
              expr         = "histogram_quantile(0.99, sum(rate(kyverno_admission_review_duration_seconds_bucket[5m])) by (le))"
              legendFormat = "p99 Latency"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "area"
            justifyMode = "auto"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "s"
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 0.5 },
                  { color = "red", value = 1 }
                ]
              }
            }
          }
        },
        {
          id      = 6
          type    = "stat"
          title   = "Admission Success Rate"
          gridPos = { h = 4, w = 4, x = 16, y = 1 }
          targets = [
            {
              expr         = "(sum(kyverno_admission_requests_total{request_allowed='true'}) / sum(kyverno_admission_requests_total) * 100) or vector(100)"
              legendFormat = "Success %"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "auto"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "percent"
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "red", value = null },
                  { color = "yellow", value = 90 },
                  { color = "green", value = 99 }
                ]
              }
            }
          }
        },
        {
          id        = 10
          type      = "row"
          title     = "Policy Results"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 5 }
        },
        {
          id      = 11
          type    = "timeseries"
          title   = "Policy Results Over Time"
          gridPos = { h = 8, w = 12, x = 0, y = 6 }
          targets = [
            {
              expr         = "sum(rate(kyverno_policy_results[5m])) by (rule_result) or vector(0)"
              legendFormat = "{{ rule_result }}"
              refId        = "A"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["mean", "lastNotNull"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "reqps"
              color = { mode = "palette-classic" }
              custom = {
                fillOpacity = 20
              }
            }
            overrides = [
              {
                matcher    = { id = "byName", options = "pass" }
                properties = [{ id = "color", value = { fixedColor = "green", mode = "fixed" } }]
              },
              {
                matcher    = { id = "byName", options = "fail" }
                properties = [{ id = "color", value = { fixedColor = "red", mode = "fixed" } }]
              }
            ]
          }
        },
        {
          id      = 12
          type    = "timeseries"
          title   = "Admission Requests by Resource"
          gridPos = { h = 8, w = 12, x = 12, y = 6 }
          targets = [
            {
              expr         = "sum(rate(kyverno_admission_requests_total[5m])) by (resource_kind)"
              legendFormat = "{{ resource_kind }}"
              refId        = "A"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["mean", "lastNotNull"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "reqps"
              color = { mode = "palette-classic" }
            }
          }
        },
        {
          id        = 20
          type      = "row"
          title     = "Violations by Policy"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 14 }
        },
        {
          id      = 21
          type    = "table"
          title   = "Policy Violations Summary"
          gridPos = { h = 8, w = 12, x = 0, y = 15 }
          targets = [
            {
              expr         = "sum(kyverno_policy_results{rule_result=\"fail\"}) by (policy_name, rule_name) or vector(0)"
              legendFormat = "{{ policy_name }} - {{ rule_name }}"
              refId        = "A"
              format       = "table"
              instant      = true
            }
          ]
          transformations = [
            {
              id = "organize"
              options = {
                excludeByName = {
                  Time = true
                }
                renameByName = {
                  policy_name = "Policy"
                  rule_name   = "Rule"
                  Value       = "Violations"
                }
              }
            },
            {
              id = "sortBy"
              options = {
                fields = {}
                sort = [
                  { field = "Violations", desc = true }
                ]
              }
            }
          ]
          options = {
            showHeader = true
            cellHeight = "sm"
          }
          fieldConfig = {
            defaults = {
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 1 },
                  { color = "red", value = 10 }
                ]
              }
            }
          }
        },
        {
          id      = 22
          type    = "timeseries"
          title   = "Violations by Namespace"
          gridPos = { h = 8, w = 12, x = 12, y = 15 }
          targets = [
            {
              expr         = "sum(rate(kyverno_policy_results{rule_result=\"fail\"}[5m])) by (resource_namespace) or vector(0)"
              legendFormat = "{{ resource_namespace }}"
              refId        = "A"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["sum", "lastNotNull"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "reqps"
              color = { mode = "palette-classic" }
            }
          }
        },
        {
          id        = 30
          type      = "row"
          title     = "Controller Health"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 23 }
        },
        {
          id      = 31
          type    = "timeseries"
          title   = "Admission Review Latency"
          gridPos = { h = 8, w = 12, x = 0, y = 24 }
          targets = [
            {
              expr         = "histogram_quantile(0.50, sum(rate(kyverno_admission_review_duration_seconds_bucket[5m])) by (le))"
              legendFormat = "p50"
              refId        = "A"
            },
            {
              expr         = "histogram_quantile(0.90, sum(rate(kyverno_admission_review_duration_seconds_bucket[5m])) by (le))"
              legendFormat = "p90"
              refId        = "B"
            },
            {
              expr         = "histogram_quantile(0.99, sum(rate(kyverno_admission_review_duration_seconds_bucket[5m])) by (le))"
              legendFormat = "p99"
              refId        = "C"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["mean", "lastNotNull"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "s"
              color = { mode = "palette-classic" }
            }
          }
        },
        {
          id      = 32
          type    = "timeseries"
          title   = "Controller Memory Usage"
          gridPos = { h = 8, w = 12, x = 12, y = 24 }
          targets = [
            {
              expr         = "sum(container_memory_working_set_bytes{namespace=\"kyverno\", container!=\"\"}) by (pod)"
              legendFormat = "{{ pod }}"
              refId        = "A"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["mean", "lastNotNull"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "bytes"
              color = { mode = "palette-classic" }
            }
          }
        }
      ]
      schemaVersion = 39
      tags          = ["kyverno", "security", "policies"]
      templating = {
        list = []
      }
      time = {
        from = "now-1h"
        to   = "now"
      }
      timepicker = {}
      timezone   = "browser"
      title      = "Kyverno Policy Metrics"
      uid        = "kyverno-policies"
      version    = 1
    })
  }
}
