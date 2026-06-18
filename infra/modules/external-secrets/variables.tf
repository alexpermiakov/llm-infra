variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for EKS"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC provider URL without https://"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt secrets"
  type        = string
}

variable "argocd_namespace" {
  description = "Namespace where ArgoCD is deployed"
  type        = string
  default     = "argocd"
}

variable "argocd_namespace_depends_on" {
  description = "Dependency on argocd namespace creation"
  type        = any
  default     = null
}

variable "github_app_secret_name" {
  description = "Name of the AWS Secrets Manager secret containing GitHub App credentials"
  type        = string
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}
