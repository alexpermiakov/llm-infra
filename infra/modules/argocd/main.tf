# Deploys ArgoCD for GitOps-based continuous delivery.
# https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "secrets_suffix" {
  byte_length = 4
}

locals {
  secret_name = "argocd/github-app-pr-${var.pr_number}-${random_id.secrets_suffix.hex}"
  secret_arn  = "arn:aws:secretsmanager:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_name}*"
}

module "secrets_kms" {
  source = "../shared/compliant-kms-key"

  name        = "argocd-secrets-pr-${var.pr_number}"
  description = "KMS key for ArgoCD secrets encryption - ${var.environment}"
  environment = var.environment
  purpose     = "secrets-encryption"

  secrets_manager_arns = [local.secret_arn]
}

resource "aws_secretsmanager_secret" "github_app" {
  name                    = local.secret_name
  description             = "GitHub App credentials for ArgoCD to access private repositories"
  kms_key_id              = module.secrets_kms.key_arn
  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  tags = {
    Name        = "ArgoCD GitHub App Credentials"
    ManagedBy   = "Terraform"
    Service     = "ArgoCD"
    Environment = var.environment
  }
}

# PCI-DSS 3.6.4, HIPAA §164.312(a)(2)(iv)
# GitHub's API requires manual action in the GitHub UI to generate a new private key.
resource "aws_secretsmanager_secret_version" "github_app_placeholder" {
  secret_id = aws_secretsmanager_secret.github_app.id
  secret_string = jsonencode({
    appID          = "PLACEHOLDER"
    installationID = "PLACEHOLDER"
    privateKey     = "PLACEHOLDER"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "purpose"                      = "gitops"
      # Pod Security Admission - baseline for platform services
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }

  timeouts {
    delete = "15m"
  }
}

# ConfigMap for Helm CMP plugin - allows using mounted values files
resource "kubernetes_config_map_v1" "cmp_plugin" {
  metadata {
    name      = "cmp-plugin"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    "helm-with-values.yaml" = <<-YAML
      apiVersion: argoproj.io/v1alpha1
      kind: ConfigManagementPlugin
      metadata:
        name: helm-with-values
      spec:
        allowConcurrency: true
        discover:
          find:
            command:
              - sh
              - "-c"
              - "find . -name 'Chart.yaml' && find . -name 'values.yaml'"
        init:
          command:
            - sh
            - "-c"
            - "helm dependency build"
        generate:
          command:
            - sh
            - "-c"
            - |
              helm template $ARGOCD_APP_NAME --include-crds -n $ARGOCD_APP_NAMESPACE . $${ARGOCD_ENV_HELM_ARGS}
        lockRepo: false
    YAML
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

resource "kubernetes_config_map_v1" "platform_values" {
  metadata {
    name      = "platform-values"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    "platform.yaml" = yamlencode({
      platform = {
        ecrRegistry = "${var.ecr_account_id}.dkr.ecr.${var.region}.amazonaws.com"
        wafAclArn   = var.waf_acl_arn
      }
    })
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.8" # Stable version before redis-ha breaking change
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  wait          = true
  wait_for_jobs = true

  values = [<<-YAML
    server:
      service:
        type: ClusterIP
      extraArgs:
        - --insecure
    
    configs:
      params:
        server.insecure: true
        # PCI-DSS 8.1.8, HIPAA §164.312(a)(2)(iii): Session timeout
        # Auto-logout after 10 minutes of inactivity (PCI max is 15 min)
        server.user.session.duration: "10m"
        # PCI-DSS 8.1.6, HIPAA §164.312(a)(2)(i): Account lockout policy
        # Lock account after 6 failed login attempts for 30 minutes
        # Prevents brute force password attacks
        server.user.session.maxFailedLoginAttempts: "6"
        server.user.session.failedLoginLockoutDuration: "30m"
      cm:
        timeout.reconciliation: "60s"
    
    # Auto-restart when github-repo-creds secret changes (via Stakater Reloader)
    applicationSet:
      podAnnotations:
        secret.reloader.stakater.com/reload: "github-repo-creds"
    
    repoServer:
      podAnnotations:
        secret.reloader.stakater.com/reload: "github-repo-creds"
      livenessProbe:
        timeoutSeconds: 10
        initialDelaySeconds: 30
        periodSeconds: 15
        failureThreshold: 5
      readinessProbe:
        timeoutSeconds: 10
        initialDelaySeconds: 10
      resources:
        requests:
          memory: 256Mi
          cpu: 250m
        limits:
          memory: 512Mi
          cpu: 500m
      
      # Mount ConfigMaps for CMP plugin and platform values
      volumes:
        - name: cmp-plugin
          configMap:
            name: cmp-plugin
        - name: platform-values
          configMap:
            name: platform-values
        - name: cmp-tmp
          emptyDir: {}
      
      # CMP sidecar for Helm with mounted values files
      extraContainers:
        - name: helm-with-values
          image: quay.io/argoproj/argocd:v2.13.3
          command: [/var/run/argocd/argocd-cmp-server]
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
          volumeMounts:
            - name: var-files
              mountPath: /var/run/argocd
            - name: plugins
              mountPath: /home/argocd/cmp-server/plugins
            - name: cmp-tmp
              mountPath: /tmp
            - name: cmp-plugin
              mountPath: /home/argocd/cmp-server/config/plugin.yaml
              subPath: helm-with-values.yaml
            - name: platform-values
              mountPath: /platform-values
  YAML
  ]

  depends_on = [
    kubernetes_namespace_v1.argocd,
    kubernetes_config_map_v1.cmp_plugin,
    kubernetes_config_map_v1.platform_values
  ]
}


resource "null_resource" "app_set" {
  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region}
      
      # Wait for ArgoCD CRDs to be available
      echo "Waiting for ArgoCD CRDs to be registered..."
      for i in {1..30}; do
        if kubectl get crd applications.argoproj.io &>/dev/null; then
          echo "ArgoCD CRDs are ready"
          break
        fi
        echo "Attempt $i/30: CRDs not ready yet, waiting 10s..."
        sleep 10
      done
      
      # Determine target revision based on environment
      if [ "${var.environment}" = "dev" ]; then
        TARGET_REVISION="${var.target_branch}"
      elif [ "${var.environment}" = "staging" ]; then
        TARGET_REVISION="main"
      else
        TARGET_REVISION="v*.*.*"
      fi
      
      # Apply ApplicationSet to auto-discover services from values files
      cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services-${var.environment}
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/alexpermiakov/paved-road-platform
        revision: $TARGET_REVISION
        files:
          - path: "argocd/applications/${var.environment}/values/*.yaml"
  template:
    metadata:
      name: "{{ trimSuffix \".yaml\" .path.filename }}"
    spec:
      project: default
      source:
        repoURL: https://github.com/alexpermiakov/paved-road-platform
        targetRevision: $TARGET_REVISION
        path: helm-charts/standard-service
        plugin:
          env:
            - name: HELM_ARGS
              value: "-f /platform-values/platform.yaml -f ../../argocd/applications/${var.environment}/values/{{.path.filename}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ trimSuffix \".yaml\" .path.filename }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        managedNamespaceMetadata:
          labels:
            waf-enabled: "true"
            environment: ${var.environment}
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
EOF
    EOT
  }

  depends_on = [helm_release.argocd]

  triggers = {
    environment    = var.environment
    target_branch  = var.target_branch
    cluster_name   = var.cluster_name
    ecr_account_id = var.ecr_account_id
    waf_acl_arn    = var.waf_acl_arn
    # Ensure re-run when ApplicationSet content changes (e.g., namespace labels)
    content_hash = "v4-cilium"
  }
}

resource "aws_ssm_parameter" "aws_region" {
  name        = "/idp/${var.environment}/platform/aws-region"
  description = "AWS region for this environment - used by Helm charts via External Secrets"
  type        = "String"
  value       = data.aws_region.current.id
  overwrite   = true

  tags = {
    Name        = "Platform AWS Region"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Dynamic ECR/service configuration"
  }
}

resource "aws_ssm_parameter" "aws_account_id" {
  name        = "/idp/${var.environment}/platform/aws-account-id"
  description = "AWS account ID for this environment - used for ECR URL construction"
  type        = "String"
  value       = data.aws_caller_identity.current.account_id
  overwrite   = true

  tags = {
    Name        = "Platform AWS Account ID"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Dynamic ECR URL construction"
  }
}
