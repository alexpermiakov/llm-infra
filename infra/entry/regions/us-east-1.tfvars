# Secondary region configuration (Passive/DR)

aws_region         = "us-east-1"
vpc_cidr_block     = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
subnet_cidr_blocks = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20", "10.0.48.0/20"]
is_primary         = false

# ECR account ID - set to your tooling account ID where ECR repos are hosted
ecr_account_id = "" # e.g., "123456789012"
