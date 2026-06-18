# Creates the network foundation: VPC, public/private subnets across AZs,
# NAT gateways, internet gateway, and route tables for EKS cluster networking.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_vpc" "idp_vpc" {
  cidr_block       = var.vpc_cidr_block
  instance_tenancy = "default"

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    "Name" = "idp_vpc-pr-${var.pr_number}"
  }
}

resource "aws_subnet" "idp_public_subnet_1a" {
  vpc_id                  = aws_vpc.idp_vpc.id
  cidr_block              = var.subnet_cidr_blocks[0]
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = {
    "Name"                   = "public_subnet_1a-pr-${var.pr_number}"
    "kubernetes.io/role/elb" = "1"
  }

  timeouts {
    delete = "20m"
  }
}

resource "aws_subnet" "idp_public_subnet_1b" {
  vpc_id                  = aws_vpc.idp_vpc.id
  cidr_block              = var.subnet_cidr_blocks[1]
  availability_zone       = var.availability_zones[1]
  map_public_ip_on_launch = true

  tags = {
    "Name"                   = "public_subnet_1b-pr-${var.pr_number}"
    "kubernetes.io/role/elb" = "1"
  }

  timeouts {
    delete = "20m"
  }
}

resource "aws_subnet" "idp_private_subnet_1a" {
  vpc_id                  = aws_vpc.idp_vpc.id
  cidr_block              = var.subnet_cidr_blocks[2]
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = false

  tags = {
    "Name"                            = "private_subnet_1a-pr-${var.pr_number}"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = "k8s-pr-${var.pr_number}"
  }

  timeouts {
    delete = "20m"
  }
}

resource "aws_subnet" "idp_private_subnet_1b" {
  vpc_id                  = aws_vpc.idp_vpc.id
  cidr_block              = var.subnet_cidr_blocks[3]
  availability_zone       = var.availability_zones[1]
  map_public_ip_on_launch = false

  tags = {
    "Name"                            = "private_subnet_1b-pr-${var.pr_number}"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = "k8s-pr-${var.pr_number}"
  }

  timeouts {
    delete = "20m"
  }
}

resource "aws_internet_gateway" "idp_ig" {
  vpc_id = aws_vpc.idp_vpc.id

  tags = {
    "Name" = "idp_ig-pr-${var.pr_number}"
  }

  timeouts {
    delete = "20m"
  }
}

resource "aws_route_table" "idp_rt" {
  vpc_id = aws_vpc.idp_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.idp_ig.id
  }

  tags = {
    "Name" = "idp_rt-pr-${var.pr_number}"
  }
}

resource "aws_route_table_association" "idp_rta" {
  subnet_id      = aws_subnet.idp_public_subnet_1a.id
  route_table_id = aws_route_table.idp_rt.id
}

resource "aws_route_table_association" "idp_rtb" {
  subnet_id      = aws_subnet.idp_public_subnet_1b.id
  route_table_id = aws_route_table.idp_rt.id
}

resource "aws_eip" "idp_eip" {
  domain = "vpc"

  tags = {
    Name = "idp_nat_eip-pr-${var.pr_number}-${var.region}"
  }

  # Ensure NAT gateway is deleted before releasing the EIP
  depends_on = [aws_internet_gateway.idp_ig]
}

resource "aws_nat_gateway" "idp_nat" {
  allocation_id = aws_eip.idp_eip.id
  subnet_id     = aws_subnet.idp_public_subnet_1a.id

  tags = {
    Name = "idp_nat-pr-${var.pr_number}-${var.region}"
  }

  # Ensure proper creation/deletion order
  depends_on = [aws_internet_gateway.idp_ig]

  timeouts {
    create = "10m"
    delete = "20m"
  }
}

resource "aws_route_table" "idp_private_rt" {
  vpc_id = aws_vpc.idp_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.idp_nat.id
  }

  tags = {
    Name = "idp_private_rt-pr-${var.pr_number}"
  }
}

resource "aws_route_table_association" "idp_private_rta" {
  subnet_id      = aws_subnet.idp_private_subnet_1a.id
  route_table_id = aws_route_table.idp_private_rt.id
}

resource "aws_route_table_association" "idp_private_rtb" {
  subnet_id      = aws_subnet.idp_private_subnet_1b.id
  route_table_id = aws_route_table.idp_private_rt.id
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.idp_vpc.id

  # No ingress or egress rules = all traffic denied

  tags = {
    Name        = "default-restricted-pr-${var.pr_number}-${var.region}"
    Description = "Default SG with all traffic restricted - do not use"
  }
}

# VPC Endpoints keep traffic on AWS backbone network.
# Required for PCI-DSS 1.3 (network segmentation) and HIPAA §164.312(e)(1).
resource "aws_security_group" "vpc_endpoints" {
  name        = "vpc-endpoints-sg-pr-${var.pr_number}-${var.region}"
  description = "Security group for VPC Interface Endpoints"
  vpc_id      = aws_vpc.idp_vpc.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "vpc-endpoints-sg-pr-${var.pr_number}-${var.region}"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# S3 Gateway Endpoint - used by EKS, Velero backups, Loki logs
# Gateway endpoints are free and work via route table entries (no ENIs)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.idp_vpc.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.idp_private_rt.id
  ]

  tags = {
    Name        = "s3-endpoint-pr-${var.pr_number}-${var.region}"
    Environment = var.environment
    Compliance  = "pci-dss-hipaa"
    ManagedBy   = "Terraform"
  }
}

locals {
  # VPC Interface Endpoints keep traffic on AWS backbone network.
  # Required for PCI-DSS 1.3 (network segmentation) and HIPAA §164.312(e)(1) (transmission security).
  interface_endpoints = {
    ecr_api              = "com.amazonaws.${var.region}.ecr.api"              # Docker auth
    ecr_dkr              = "com.amazonaws.${var.region}.ecr.dkr"              # Docker layer downloads
    secretsmanager       = "com.amazonaws.${var.region}.secretsmanager"       # External Secrets Operator
    kms                  = "com.amazonaws.${var.region}.kms"                  # Encryption/decryption
    logs                 = "com.amazonaws.${var.region}.logs"                 # CloudWatch Logs
    sts                  = "com.amazonaws.${var.region}.sts"                  # IRSA token exchange
    ec2                  = "com.amazonaws.${var.region}.ec2"                  # Karpenter node provisioning
    ssm                  = "com.amazonaws.${var.region}.ssm"                  # Systems Manager
    autoscaling          = "com.amazonaws.${var.region}.autoscaling"          # EKS node groups
    elasticloadbalancing = "com.amazonaws.${var.region}.elasticloadbalancing" # ALB/NLB management
    sns                  = "com.amazonaws.${var.region}.sns"                  # Security alerts
    sqs                  = "com.amazonaws.${var.region}.sqs"                  # Message queues
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.idp_vpc.id
  service_name      = each.value
  vpc_endpoint_type = "Interface"
  # Dev needs public ALB access - private DNS breaks DNS resolution for public subnets
  # Prod should set this to true since ALB is internal-only
  private_dns_enabled = var.environment != "dev"

  subnet_ids = [
    aws_subnet.idp_private_subnet_1a.id,
    aws_subnet.idp_private_subnet_1b.id
  ]

  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name        = "${each.key}-endpoint-pr-${var.pr_number}-${var.region}"
    Environment = var.environment
    Compliance  = "pci-dss-hipaa"
    ManagedBy   = "Terraform"
  }
}
