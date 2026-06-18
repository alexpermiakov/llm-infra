output "namespace" {
  description = "ArgoCD namespace"
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "github_app_secret_name" {
  description = "Name of the GitHub App credentials secret"
  value       = aws_secretsmanager_secret.github_app.name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for secrets encryption"
  value       = module.secrets_kms.key_arn
}
