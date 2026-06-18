variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used as ipv4NativeRoutingCIDR so Cilium uses native VPC routing instead of VXLAN tunnels in aws-cni chaining mode"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint — required for Cilium kube-proxy replacement in ENI mode (Phase 3+). Cilium agents need to reach the API server directly because kube-proxy iptables rules are no longer providing the kubernetes Service ClusterIP."
  type        = string
}

variable "enable_service_monitors" {
  description = "Whether to create ServiceMonitor objects for Cilium agent, operator, and Hubble. Requires the monitoring.coreos.com/v1 CRD (installed by kube-prometheus-stack). Keep false on greenfield apply (Cilium installs before monitoring); flip to true and re-apply once monitoring is up."
  type        = bool
  default     = false
}
