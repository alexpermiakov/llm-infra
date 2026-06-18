# Velero Backup for Kubernetes - PCI-DSS 12.10.1, HIPAA §164.308(a)(7)

terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "velero_bucket" {
  source = "../shared/compliant-s3-bucket"

  bucket_name   = "Velero Backups"
  bucket_prefix = "velero-backups"
  environment   = var.environment
  purpose       = "kubernetes-backup"

  object_lock_retention_days = 90
  compliance_retention_days  = 2555
  non_prod_retention_days    = 90

  lifecycle_transitions = [
    { days = 30, storage_class = "STANDARD_IA" },
    { days = 90, storage_class = "GLACIER" },
    { days = 365, storage_class = "DEEP_ARCHIVE" }
  ]
  non_prod_transitions = [
    { days = 30, storage_class = "STANDARD_IA" }
  ]
}

resource "aws_iam_role" "velero" {
  name = "${var.cluster_name}-velero"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.oidc_provider}:sub" = "system:serviceaccount:velero:velero-server"
            "${var.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-velero"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy" "velero" {
  name = "velero-backup-policy"
  role = aws_iam_role.velero.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          module.velero_bucket.bucket_arn,
          "${module.velero_bucket.bucket_arn}/*"
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = module.velero_bucket.kms_key_arn
      },
      {
        Sid    = "EC2Snapshots"
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:CreateSnapshots",
          "ec2:DeleteSnapshot",
          "ec2:DescribeSnapshots",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeAttribute",
          "ec2:DescribeVolumeStatus",
          "ec2:CreateTags"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.id
          }
        }
      },
      {
        Sid    = "EC2VolumeRestore"
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.id
          }
        }
      }
    ]
  })
}

# Velero Helm Release
resource "helm_release" "velero" {
  name             = "velero"
  namespace        = "velero"
  create_namespace = true
  repository       = "https://vmware-tanzu.github.io/helm-charts"
  chart            = "velero"
  version          = "11.3.2"

  timeout = 600

  values = [
    yamlencode({
      initContainers = [
        {
          name  = "velero-plugin-for-aws"
          image = "velero/velero-plugin-for-aws:v1.13.2"
          volumeMounts = [
            {
              name      = "plugins"
              mountPath = "/target"
            }
          ]
        }
      ]

      configuration = {
        backupStorageLocation = [
          {
            name     = "default"
            provider = "aws"
            bucket   = module.velero_bucket.bucket_id
            config = {
              region   = data.aws_region.current.id
              kmsKeyId = module.velero_bucket.kms_key_arn
            }
          }
        ]
        volumeSnapshotLocation = [
          {
            name     = "default"
            provider = "aws"
            config = {
              region = data.aws_region.current.id
            }
          }
        ]
        defaultBackupStorageLocation   = "default"
        defaultVolumeSnapshotLocations = "aws:default"
      }

      serviceAccount = {
        server = {
          create = true
          name   = "velero-server"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.velero.arn
          }
        }
      }

      credentials = {
        useSecret = false # Using IRSA instead
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }

      # Deploy on any node
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
      ]

      metrics = {
        enabled = true
        serviceMonitor = {
          enabled = true
        }
      }

      # Fix for broken default kubectl image in CRD upgrade job
      kubectl = {
        image = {
          repository = "bitnami/kubectl"
          tag        = "1.31"
        }
      }

      # Disable the CRD upgrade Job hook - it uses a broken image
      # CRDs will still be installed via Helm's standard crds/ folder mechanism
      upgradeCRDs = false
    })
  ]
}

# Backup Schedule - HIPAA §164.308(a)(7)(ii)(A): Data backup plan
resource "kubectl_manifest" "backup_schedule" {
  yaml_body = yamlencode({
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "${var.environment}-backup"
      namespace = "velero"
    }
    spec = {
      schedule = var.environment == "prod" ? "0 2 * * *" : "0 3 * * 0" # Daily for prod, weekly for non-prod
      template = {
        ttl                     = var.environment == "prod" ? "2160h" : "336h" # 90 days prod, 14 days non-prod
        includedNamespaces      = ["*"]
        excludedNamespaces      = ["velero", "kube-system", "kube-public", "kube-node-lease"]
        includeClusterResources = true
        snapshotVolumes         = true
        storageLocation         = "default"
        volumeSnapshotLocations = ["default"]
      }
    }
  })

  depends_on = [helm_release.velero]
}



# Backup Monitoring - HIPAA §164.308(a)(7), PCI-DSS 12.10.1, SOC 2 A1.3
resource "aws_s3_bucket_metric" "velero_requests" {
  bucket = module.velero_bucket.bucket_id
  name   = "BackupUploads"

  filter {
    prefix = "backups/"
  }
}

# Alarm if no PUT requests (no backups uploaded) in 26 hours
resource "aws_cloudwatch_metric_alarm" "no_backup_uploads" {
  alarm_name          = "velero-no-backup-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "PutRequests"
  namespace           = "AWS/S3"
  period              = 93600 # 26 hours (gives buffer for 24h schedule)
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching" # No data = no backups = alarm!
  alarm_description   = "No Velero backups uploaded in 26 hours - HIPAA/PCI compliance risk"

  dimensions = {
    BucketName = module.velero_bucket.bucket_id
    FilterId   = "BackupUploads"
  }

  tags = {
    Environment = var.environment
    Severity    = "critical"
    Compliance  = "hipaa-pci-dss"
    ManagedBy   = "Terraform"
  }
}

# Additional: Monitor S3 bucket for 4xx/5xx errors during backup writes
resource "aws_cloudwatch_metric_alarm" "backup_s3_errors" {
  alarm_name          = "velero-s3-errors-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5xxErrors"
  namespace           = "AWS/S3"
  period              = 3600 # 1 hour
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "S3 errors during Velero backup operations"

  dimensions = {
    BucketName = module.velero_bucket.bucket_id
    FilterId   = "BackupUploads"
  }

  tags = {
    Environment = var.environment
    Severity    = "high"
    Compliance  = "hipaa-pci-dss"
    ManagedBy   = "Terraform"
  }
}
