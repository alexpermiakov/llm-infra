# See https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md
# for available pod metrics

resource "kubernetes_config_map_v1" "platform_dashboard" {
  metadata {
    name      = "grafana-dashboard-platform"
    namespace = var.namespace
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "Platform"
    }
  }

  data = {
    "platform-overview.json" = jsonencode({
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
          title     = "Platform Overview"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 0 }
        },
        {
          id      = 2
          type    = "stat"
          title   = "Running Pods"
          gridPos = { h = 4, w = 4, x = 0, y = 1 }
          targets = [
            {
              expr         = "sum(kube_pod_status_phase{phase=\"Running\"})"
              legendFormat = "Pods"
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
                  { color = "green", value = null }
                ]
              }
            }
          }
        },
        {
          id      = 3
          type    = "stat"
          title   = "Namespaces"
          gridPos = { h = 4, w = 4, x = 4, y = 1 }
          targets = [
            {
              expr         = "count(kube_namespace_status_phase{phase=\"Active\"})"
              legendFormat = "Namespaces"
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
          id      = 4
          type    = "stat"
          title   = "Deployments"
          gridPos = { h = 4, w = 4, x = 8, y = 1 }
          targets = [
            {
              expr         = "count(kube_deployment_status_replicas)"
              legendFormat = "Deployments"
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
                  { color = "purple", value = null }
                ]
              }
            }
          }
        },
        {
          id      = 5
          type    = "stat"
          title   = "Cluster CPU Usage"
          gridPos = { h = 4, w = 6, x = 12, y = 1 }
          targets = [
            {
              expr         = "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)"
              legendFormat = "CPU %"
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
              unit  = "percent"
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 60 },
                  { color = "red", value = 80 }
                ]
              }
            }
          }
        },
        {
          id      = 6
          type    = "stat"
          title   = "Cluster Memory Usage"
          gridPos = { h = 4, w = 6, x = 18, y = 1 }
          targets = [
            {
              expr         = "(1 - (sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes))) * 100"
              legendFormat = "Memory %"
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
              unit  = "percent"
              color = { mode = "thresholds" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 60 },
                  { color = "red", value = 80 }
                ]
              }
            }
          }
        },
        {
          id        = 10
          type      = "row"
          title     = "Application Services"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 5 }
        },
        {
          id      = 11
          type    = "table"
          title   = "Deployment Status"
          gridPos = { h = 8, w = 12, x = 0, y = 6 }
          targets = [
            {
              expr         = "sort_desc(kube_deployment_status_replicas_available)"
              legendFormat = "{{ namespace }}/{{ deployment }}"
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
                  instance = true
                  job      = true
                  uid      = true
                }
                renameByName = {
                  deployment = "Deployment"
                  namespace  = "Namespace"
                  Value      = "Available Replicas"
                }
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
                  { color = "red", value = null },
                  { color = "green", value = 1 }
                ]
              }
            }
          }
        },
        {
          id      = 12
          type    = "timeseries"
          title   = "Pod CPU Usage by Namespace"
          gridPos = { h = 8, w = 12, x = 12, y = 6 }
          targets = [
            {
              expr         = "sum(rate(container_cpu_usage_seconds_total{container!=\"\", container!=\"POD\"}[5m])) by (namespace)"
              legendFormat = "{{ namespace }}"
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
              unit  = "short"
              color = { mode = "palette-classic" }
            }
          }
        },
        {
          id        = 20
          type      = "row"
          title     = "Pod Health & Restarts"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 14 }
        },
        {
          id      = 21
          type    = "timeseries"
          title   = "Pod Restarts (Last 24h)"
          gridPos = { h = 8, w = 12, x = 0, y = 15 }
          targets = [
            {
              expr         = "increase(kube_pod_container_status_restarts_total[24h])"
              legendFormat = "{{ namespace }}/{{ pod }}"
              refId        = "A"
            }
          ]
          options = {
            legend = {
              displayMode = "table"
              placement   = "right"
              calcs       = ["lastNotNull"]
            }
          }
          fieldConfig = {
            defaults = {
              unit  = "short"
              color = { mode = "palette-classic" }
              thresholds = {
                mode = "absolute"
                steps = [
                  { color = "green", value = null },
                  { color = "yellow", value = 1 },
                  { color = "red", value = 5 }
                ]
              }
            }
          }
        },
        {
          id      = 22
          type    = "timeseries"
          title   = "Memory Usage by Pod"
          gridPos = { h = 8, w = 12, x = 12, y = 15 }
          targets = [
            {
              expr         = "sum(container_memory_working_set_bytes{container!=\"\", container!=\"POD\"}) by (namespace, pod) / 1024 / 1024"
              legendFormat = "{{ namespace }}/{{ pod }}"
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
              unit  = "decmbytes"
              color = { mode = "palette-classic" }
            }
          }
        },
        {
          id        = 30
          type      = "row"
          title     = "Network"
          collapsed = false
          gridPos   = { h = 1, w = 24, x = 0, y = 23 }
        },
        {
          id      = 31
          type    = "timeseries"
          title   = "Network I/O by Namespace"
          gridPos = { h = 8, w = 24, x = 0, y = 24 }
          targets = [
            {
              expr         = "sum(rate(container_network_receive_bytes_total[5m])) by (namespace)"
              legendFormat = "{{ namespace }} (RX)"
              refId        = "A"
            },
            {
              expr         = "sum(rate(container_network_transmit_bytes_total[5m])) by (namespace)"
              legendFormat = "{{ namespace }} (TX)"
              refId        = "B"
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
              unit  = "Bps"
              color = { mode = "palette-classic" }
            }
          }
        }
      ]
      schemaVersion = 39
      tags          = ["platform", "kubernetes", "idp"]
      templating = {
        list = []
      }
      time = {
        from = "now-1h"
        to   = "now"
      }
      timepicker = {}
      timezone   = "browser"
      title      = "Platform Overview"
      uid        = "platform-overview"
      version    = 1
    })
  }
}
