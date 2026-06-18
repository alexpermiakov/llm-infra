output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider" {
  description = "OIDC provider URL without https://"
  value       = module.eks.oidc_provider
}

output "aws_load_balancer_controller_irsa_role_arn" {
  description = "ARN of the IAM role for the AWS Load Balancer Controller"
  value       = module.aws_load_balancer_controller_irsa.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for EKS encryption"
  value       = module.eks_kms.key_arn
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes"
  value       = module.eks.node_security_group_id
}

output "ebs_csi_irsa_role_arn" {
  description = "ARN of the IRSA role for the aws-ebs-csi-driver addon"
  value       = module.ebs_csi_irsa.arn
}

output "addon_versions" {
  description = "Pinned versions for cluster-critical EKS managed addons"
  value       = local.addon_versions
}
