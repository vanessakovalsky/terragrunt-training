# environments/terragrunt.hcl
locals {
  # Variables d'environnement
  environment = basename(get_terragrunt_dir())
  region      = get_env("AWS_DEFAULT_REGION", "us-east-2")
  project     = "secure-pipeline"
  
  # Configuration par environnement
  env_vars = {
    dev = {
      instance_type = "t3.micro"
      min_size     = 1
      max_size     = 2
    }
    staging = {
      instance_type = "t3.small"
      min_size     = 2
      max_size     = 4
    }
    prod = {
      instance_type = "t3.medium"
      min_size     = 3
      max_size     = 10
    }
  }
  
  # Tags de sécurité
  security_tags = {
    Environment     = local.environment
    Project        = local.project
    ManagedBy      = "terragrunt"
    SecurityLevel  = local.environment == "prod" ? "high" : "medium"
    DataClass      = "internal"
    Owner          = get_env("PIPELINE_OWNER", "devops-team")
    CostCenter     = get_env("COST_CENTER", "engineering")
    DeployedBy     = get_env("CI_PIPELINE_ID", "manual")
    DeployedAt     = formatdate("YYYY-MM-DD-hhmm", timestamp())
  }
}

# Configuration du backend avec chiffrement
remote_state {
  backend = "s3"
  config = {
    bucket = "secure-terragrunt-state-${local.environment}"
    key    = "${path_relative_to_include()}/terraform.tfstate"
    region = local.region
    
    # Sécurité renforcée
    encrypt                = true
    kms_key_id            = "arn:aws:kms:${local.region}:${get_aws_account_id()}:key/pipeline-state"
    dynamodb_table        = "terragrunt-locks-${local.environment}"
    skip_bucket_versioning = false
    
    # Politique de rétention
    lifecycle_configuration = {
      rule = {
        id     = "state_retention"
        status = "Enabled"
        
        noncurrent_version_expiration = {
          days = 90
        }
      }
    }
  }
}

# Provider avec contraintes de sécurité
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.0"
}

provider "aws" {
  region = "${local.region}"
  
  # Contraintes de sécurité
  allowed_account_ids = ["${get_aws_account_id()}"]
  
  default_tags {
    tags = ${jsonencode(local.security_tags)}
  }
  
  # Assume role pour sécurité accrue
  assume_role {
    role_arn = "arn:aws:iam::${get_aws_account_id()}:role/TerragruntDeployRole-${title(local.environment)}"
  }
}
EOF
}

# Hooks de sécurité globaux
terraform {
  before_hook "security_check" {
    commands = ["plan", "apply"]
    execute = [
      "bash", "-c", <<-EOT
        echo "🔐 Running security checks..."
        # Vérification des credentials
        aws sts get-caller-identity
        # Vérification de l'environnement
        if [[ "${local.environment}" == "prod" && "${get_env("CI_COMMIT_REF_NAME", "")}" != "main" ]]; then
          echo "❌ Production deployments only allowed from main branch"
          exit 1
        fi
      EOT
    ]
  }
  
  before_hook "cost_estimation" {
    commands = ["plan"]
    execute = [
      "bash", "-c", <<-EOT
        echo "💰 Estimating infrastructure costs..."
        # Integration avec Infracost si disponible
        if command -v infracost &> /dev/null; then
          infracost breakdown --path=.
        fi
      EOT
    ]
  }
  
  after_hook "compliance_check" {
    commands = ["apply"]
    execute = [
      "bash", "-c", <<-EOT
        echo "📋 Running compliance checks..."
        # Vérification des tags obligatoires
        aws resourcegroupstaggingapi get-resources --region ${local.region} \
          --tag-filters Key=Environment,Values=${local.environment} \
          --query 'ResourceTagMappingList[?!Tags[?Key==`Owner`]]' || true
      EOT
    ]
  }
}