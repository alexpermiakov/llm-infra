output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "region" {
  description = "AWS region for this cluster"
  value       = var.aws_region
}

output "is_primary" {
  description = "Whether this is the primary region"
  value       = var.is_primary
}

output "waf_web_acl_arn" {
  description = "ARN of the WAF Web ACL for attaching to ALB ingresses"
  value       = module.waf.web_acl_arn
}

output "waf_web_acl_name" {
  description = "Name of the WAF Web ACL"
  value       = module.waf.web_acl_name
}
