terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  region = "us-east-1"
  alias  = "secondary"
}

data "aws_organizations_organization" "org" {}

locals {
  # Define ECR repositories for each microservice.
  # These will be used for image storage and vulnerability scanning.
  ecr_repositories = {
    "llm-client"    = "LLM Client"
    "order-service" = "Order Service"
  }
}

resource "aws_ecr_replication_configuration" "cross_region" {
  replication_configuration {
    rule {
      destination {
        region      = "us-east-1"
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = "idp/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "apps" {
  for_each             = local.ecr_repositories
  name                 = "idp/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = {
    Name = each.value
  }
}

# SBOMs are attached as cosign attestations to images
# FDA, SOC2, PCI-DSS 6.2 require retention of software artifacts
resource "aws_ecr_lifecycle_policy" "compliance_retention" {
  for_each   = aws_ecr_repository.apps
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep all tagged images for 3 years (compliance)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = 1095
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository_policy" "allow_cross_account_pull" {
  for_each   = aws_ecr_repository.apps
  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOrganizationPull"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.org.id
          }
        }
      }
    ]
  })
}

output "organization_id" {
  value = data.aws_organizations_organization.org.id
}

output "ecr_account_id" {
  description = "AWS account ID for ECR (use this as ecr_account_id variable in entry environments)"
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_repositories" {
  value = { for k, v in aws_ecr_repository.apps : k => v.repository_url }
}
