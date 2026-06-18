# See slo.tf for Prometheus recording rules & alerts
# https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/

resource "kubernetes_config_map_v1" "slo_dashboard" {
  metadata {
    name      = "grafana-dashboard-slo"
    namespace = var.namespace
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "Platform"
    }
  }

  data = {
    "slo-overview.json" = jsonencode({
      annotations = {
        list = [
          {
            builtIn    = 1
            datasource = { type = "grafana", uid = "-- Grafana --" }
            enable     = true
            hide       = true
            iconColor  = "rgba(255, 96, 96, 1)"
            name       = "SLO Alerts"
            type       = "dashboard"
          }
        ]
      }
      editable             = true
      fiscalYearStartMonth = 0
      graphTooltip         = 1
      id                   = null
      links                = []
      liveNow              = false
      panels = [
        # Row: Executive Summary
        {
          id        = 1
          type      = "row"
          title     = "📊 Executive Summary"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 0 }
        },
        # Current Availability
        {
          id      = 2
          type    = "gauge"
          title   = "Current Availability"
          gridPos = { h = 6, w = 6, x = 0, y = 1 }
          targets = [
            {
              expr         = "avg(sli:http_requests:success_rate_5m) or vector(1)"
              legendFormat = "Availability"
              refId        = "A"
            }
          ]
          options = {
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
            showThresholdLabels  = false
            showThresholdMarkers = true
          }
          fieldConfig = {
            defaults = {
              unit     = "percentunit"
              decimals = 3
              min      = 0.99
              max      = 1
              color    = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "red", value = null },
                  { color = "orange", value = 0.99 },
                  { color = "yellow", value = 0.999 },
                  { color = "green", value = 0.9999 }
                ]
              }
            }
          }
        },
        # Error Budget Remaining
        {
          id      = 3
          type    = "gauge"
          title   = "Error Budget Remaining"
          gridPos = { h = 6, w = 6, x = 6, y = 1 }
          targets = [
            {
              expr         = "avg(slo:http_requests:error_budget_remaining) or vector(1)"
              legendFormat = "Budget"
              refId        = "A"
            }
          ]
          options = {
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
            showThresholdLabels  = false
            showThresholdMarkers = true
          }
          fieldConfig = {
            defaults = {
              unit     = "percentunit"
              decimals = 1
              min      = 0
              max      = 1
              color    = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "red", value = null },
                  { color = "orange", value = 0.25 },
                  { color = "yellow", value = 0.5 },
                  { color = "green", value = 0.75 }
                ]
              }
            }
          }
        },
        # Active Incidents
        {
          id      = 4
          type    = "stat"
          title   = "🚨 Active Incidents"
          gridPos = { h = 6, w = 4, x = 12, y = 1 }
          targets = [
            {
              expr         = "count(service:incident:in_progress == 1) or vector(0)"
              legendFormat = "Incidents"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "background"
            graphMode   = "none"
            justifyMode = "center"
            textMode    = "value"
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
                  { color = "red", value = 1 }
                ]
              }
              mappings = [
                {
                  type = "value"
                  options = {
                    "0" = { text = "All Clear", color = "green" }
                  }
                }
              ]
            }
          }
        },
        # P99 Latency
        {
          id      = 5
          type    = "stat"
          title   = "P99 Latency"
          gridPos = { h = 6, w = 4, x = 16, y = 1 }
          targets = [
            {
              expr         = "avg(sli:http_request_duration:p99_5m) or vector(0)"
              legendFormat = "P99"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "area"
            justifyMode = "center"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              unit     = "s"
              decimals = 0
              color    = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 0.3 },
                  { color = "red", value = 0.5 }
                ]
              }
            }
          }
        },
        # 30-Day Availability (SLA)
        {
          id      = 6
          type    = "stat"
          title   = "30-Day Availability (SLA)"
          gridPos = { h = 6, w = 4, x = 20, y = 1 }
          targets = [
            {
              expr         = "avg(slo:availability:30d) or vector(1)"
              legendFormat = "30d Availability"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "center"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              unit     = "percentunit"
              decimals = 3
              color    = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "red", value = null },
                  { color = "yellow", value = 0.999 },
                  { color = "green", value = 0.9995 }
                ]
              }
            }
          }
        },
        # Row: Service Health
        {
          id        = 10
          type      = "row"
          title     = "🔥 Error Budget & Availability"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 7 }
        },
        # Success Rate Over Time
        {
          id      = 11
          type    = "timeseries"
          title   = "Service Success Rate"
          gridPos = { h = 8, w = 12, x = 0, y = 8 }
          targets = [
            {
              expr         = "sli:http_requests:success_rate_5m"
              legendFormat = "{{ namespace }}/{{ service }}"
              refId        = "A"
            },
            {
              expr         = "slo:http_requests:availability_target"
              legendFormat = "SLO Target (99.9%)"
              refId        = "B"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["min", "mean", "lastNotNull"]
            }
            tooltip = {
              mode = "multi"
              sort = "desc"
            }
          }
          fieldConfig = {
            defaults = {
              unit     = "percentunit"
              decimals = 3
              min      = 0.95
              max      = 1
              color    = { mode = "palette-classic" }
              custom = {
                lineWidth   = 2
                fillOpacity = 10
                spanNulls   = true
              }
            }
            overrides = [
              {
                matcher = { id = "byName", options = "SLO Target (99.9%)" }
                properties = [
                  { id = "color", value = { mode = "fixed", fixedColor = "red" } },
                  { id = "custom.lineStyle", value = { fill = "dash", dash = [10, 10] } },
                  { id = "custom.lineWidth", value = 1 }
                ]
              }
            ]
          }
        },
        # Error Budget Burn Rate
        {
          id      = 12
          type    = "timeseries"
          title   = "Error Budget Remaining"
          gridPos = { h = 8, w = 12, x = 12, y = 8 }
          targets = [
            {
              expr         = "slo:http_requests:error_budget_remaining"
              legendFormat = "{{ namespace }}/{{ service }}"
              refId        = "A"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["min", "lastNotNull"]
            }
            tooltip = {
              mode = "multi"
              sort = "desc"
            }
          }
          fieldConfig = {
            defaults = {
              unit     = "percentunit"
              decimals = 1
              min      = -0.5
              max      = 1
              color    = { mode = "palette-classic" }
              custom = {
                lineWidth       = 2
                fillOpacity     = 20
                gradientMode    = "scheme"
                thresholdsStyle = { mode = "area" }
              }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "red", value = null },
                  { color = "orange", value = 0 },
                  { color = "yellow", value = 0.5 },
                  { color = "green", value = 0.75 }
                ]
              }
            }
          }
        },
        # Row: Incidents
        {
          id        = 20
          type      = "row"
          title     = "🚨 Incident Tracking"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 16 }
        },
        # Incident Timeline
        {
          id      = 21
          type    = "state-timeline"
          title   = "Incident Timeline (Service Degradation)"
          gridPos = { h = 6, w = 16, x = 0, y = 17 }
          targets = [
            {
              expr         = "service:incident:in_progress"
              legendFormat = "{{ namespace }}/{{ service }}"
              refId        = "A"
            }
          ]
          options = {
            showValue   = "never"
            mergeValues = true
            alignValue  = "center"
            legend = {
              displayMode = "list"
              placement   = "bottom"
            }
          }
          fieldConfig = {
            defaults = {
              color = { mode = "thresholds" }
              custom = {
                fillOpacity = 80
              }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "red", value = 1 }
                ]
              }
              mappings = [
                {
                  type = "value"
                  options = {
                    "0" = { text = "Healthy", color = "green" }
                    "1" = { text = "Degraded", color = "red" }
                  }
                }
              ]
            }
          }
        },
        # Incident Stats
        {
          id      = 22
          type    = "stat"
          title   = "Incidents (30 days)"
          gridPos = { h = 6, w = 4, x = 16, y = 17 }
          targets = [
            {
              expr         = "sum(service:incidents:count_30d) or vector(0)"
              legendFormat = "Total"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "center"
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
                  { color = "yellow", value = 5 },
                  { color = "red", value = 20 }
                ]
              }
            }
          }
        },
        # Active Incident Duration
        {
          id      = 23
          type    = "stat"
          title   = "Current Incident Duration"
          gridPos = { h = 6, w = 4, x = 20, y = 17 }
          targets = [
            {
              expr         = "max(slo:active_incident:duration_seconds > 0) or vector(0)"
              legendFormat = "Duration"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "center"
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
                  { color = "yellow", value = 300 },
                  { color = "red", value = 900 }
                ]
              }
            }
          }
        },
        # Row: Latency
        {
          id        = 30
          type      = "row"
          title     = "⏱️ Latency Performance"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 23 }
        },
        # P99 Latency Over Time
        {
          id      = 31
          type    = "timeseries"
          title   = "P99 Latency vs Target"
          gridPos = { h = 8, w = 12, x = 0, y = 24 }
          targets = [
            {
              expr         = "sli:http_request_duration:p99_5m"
              legendFormat = "{{ namespace }}/{{ service }}"
              refId        = "A"
            },
            {
              expr         = "slo:http_request_duration:latency_target_seconds"
              legendFormat = "SLO Target (500ms)"
              refId        = "B"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["max", "mean", "lastNotNull"]
            }
            tooltip = {
              mode = "multi"
              sort = "desc"
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "s"
              color = { mode = "palette-classic" }
              custom = {
                lineWidth   = 2
                fillOpacity = 10
              }
            }
            overrides = [
              {
                matcher = { id = "byName", options = "SLO Target (500ms)" }
                properties = [
                  { id = "color", value = { mode = "fixed", fixedColor = "red" } },
                  { id = "custom.lineStyle", value = { fill = "dash", dash = [10, 10] } },
                  { id = "custom.lineWidth", value = 1 }
                ]
              }
            ]
          }
        },
        # MTTD
        {
          id      = 32
          type    = "stat"
          title   = "Mean Time To Detect (MTTD)"
          gridPos = { h = 4, w = 6, x = 12, y = 24 }
          targets = [
            {
              expr         = "avg(slo:mttd:seconds) or vector(0)"
              legendFormat = "MTTD"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "area"
            justifyMode = "center"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["mean"]
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
                  { color = "yellow", value = 60 },
                  { color = "red", value = 300 }
                ]
              }
            }
          }
        },
        # Estimated Downtime
        {
          id      = 33
          type    = "stat"
          title   = "Est. Downtime This Month"
          gridPos = { h = 4, w = 6, x = 18, y = 24 }
          targets = [
            {
              expr         = "(1 - avg(slo:availability:30d)) * 30 * 24 * 60"
              legendFormat = "Minutes"
              refId        = "A"
            }
          ]
          options = {
            colorMode   = "value"
            graphMode   = "none"
            justifyMode = "center"
            textMode    = "auto"
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
          }
          fieldConfig = {
            defaults = {
              unit     = "m"
              decimals = 1
              color    = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 30 },
                  { color = "red", value = 43.2 } # 99.9% SLO = 43.2 min/month
                ]
              }
            }
          }
        },
        # SLO Budget Allocation
        {
          id      = 34
          type    = "piechart"
          title   = "Error Budget Allocation"
          gridPos = { h = 4, w = 6, x = 12, y = 28 }
          targets = [
            {
              expr         = "(1 - avg(slo:http_requests:error_budget_remaining)) * 100"
              legendFormat = "Consumed"
              refId        = "A"
            },
            {
              expr         = "avg(slo:http_requests:error_budget_remaining) * 100"
              legendFormat = "Remaining"
              refId        = "B"
            }
          ]
          options = {
            reduceOptions = {
              calcs  = ["lastNotNull"]
              fields = ""
              values = false
            }
            pieType       = "donut"
            displayLabels = ["percent"]
            legend = {
              displayMode = "table"
              placement   = "right"
              values      = ["percent"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "percent"
              color = { mode = "palette-classic" }
            }
            overrides = [
              {
                matcher = { id = "byName", options = "Consumed" }
                properties = [
                  { id = "color", value = { mode = "fixed", fixedColor = "orange" } }
                ]
              },
              {
                matcher = { id = "byName", options = "Remaining" }
                properties = [
                  { id = "color", value = { mode = "fixed", fixedColor = "green" } }
                ]
              }
            ]
          }
        },
        # SLO Compliance Table
        {
          id      = 35
          type    = "table"
          title   = "Service SLO Compliance"
          gridPos = { h = 4, w = 6, x = 18, y = 28 }
          targets = [
            {
              expr         = "sli:http_requests:success_rate_5m"
              legendFormat = ""
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
                  Time     = true
                  __name__ = true
                }
                renameByName = {
                  namespace = "Namespace"
                  service   = "Service"
                  Value     = "Success Rate"
                }
              }
            }
          ]
          options = {
            showHeader = true
            cellHeight = "sm"
            sortBy = [
              { displayName = "Success Rate", desc = false }
            ]
          }
          fieldConfig = {
            defaults = {
              unit     = "percentunit"
              decimals = 3
              color    = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "red", value = null },
                  { color = "yellow", value = 0.99 },
                  { color = "green", value = 0.999 }
                ]
              }
              custom = {
                displayMode = "color-background-solid"
              }
            }
          }
        },
        # Row: Alerts
        {
          id        = 40
          type      = "row"
          title     = "🔔 Active SLO Alerts"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 32 }
        },
        # Alert List
        {
          id      = 41
          type    = "alertlist"
          title   = "SLO Alert Status"
          gridPos = { h = 6, w = 24, x = 0, y = 33 }
          options = {
            alertName       = "SLO"
            dashboardAlerts = false
            groupBy         = []
            groupMode       = "default"
            maxItems        = 20
            sortOrder       = 1
            stateFilter = {
              "error"   = true
              "firing"  = true
              "noData"  = false
              "normal"  = false
              "pending" = true
            }
            viewMode = "list"
          }
        }
      ]
      schemaVersion = 39
      tags          = ["slo", "sli", "reliability", "incidents", "platform"]
      templating = {
        list = [
          {
            name       = "namespace"
            type       = "query"
            datasource = { type = "prometheus", uid = "prometheus" }
            query      = "label_values(sli:http_requests:success_rate_5m, namespace)"
            refresh    = 2
            includeAll = true
            multi      = true
            current = {
              selected = true
              text     = "All"
              value    = "$__all"
            }
          },
          {
            name       = "service"
            type       = "query"
            datasource = { type = "prometheus", uid = "prometheus" }
            query      = "label_values(sli:http_requests:success_rate_5m{namespace=~\"$namespace\"}, service)"
            refresh    = 2
            includeAll = true
            multi      = true
            current = {
              selected = true
              text     = "All"
              value    = "$__all"
            }
          }
        ]
      }
      time = {
        from = "now-24h"
        to   = "now"
      }
      timepicker = {
        refresh_intervals = ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h"]
      }
      timezone = "browser"
      title    = "SLO Overview"
      uid      = "slo-overview"
      version  = 1
    })
  }
}
