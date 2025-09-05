# Configuration globale pour tous les modules
locals {
  # Variables communes
  aws_region = "us-east-2"
  environment = "dev"
  project_name = "hooks-exercise"
  
  # Tags par défaut
  common_tags = {
    Environment = local.environment
    Project = local.project_name
    ManagedBy = "terragrunt"
  }
}

# Génération SEULEMENT du provider (sans required_providers)
generate "provider" {
  path = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents = <<EOF
provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = ${jsonencode(local.common_tags)}
  }
}
EOF
}

# Génération du bloc backend requis
generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents = <<EOF
terraform {
  backend "s3" {}
}
EOF
}

# Configuration du backend S3
remote_state {
  backend = "s3"
  config = {
    bucket = "vanessa-state-bucket"
    key = "${path_relative_to_include()}/terraform.tfstate"
    region = "us-east-2"
    dynamodb_table = "terragrunt-locks"
    encrypt = true
  }
}