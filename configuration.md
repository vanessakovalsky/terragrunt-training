### 🛠️ TP : Création d'une structure multi-environnements

#### Objectif

Créer une structure Terragrunt complète avec 3 environnements (dev, staging, prod) et un module VPC.

#### Étapes

1. **Initialisation du projet**
```bash
mkdir formation-terragrunt
cd formation-terragrunt
```

2. **Création de la structure**
```bash
# Structure des dossiers
mkdir -p {modules/vpc,environments/{dev,staging,prod}/vpc}
touch terragrunt.hcl
touch environments/{dev,staging,prod}/account.hcl
touch environments/{dev,staging,prod}/vpc/terragrunt.hcl
```

3. **Module VPC (modules/vpc/main.tf)**
```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = merge(var.tags, {
    Name = var.vpc_name
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = merge(var.tags, {
    Name = "${var.vpc_name}-igw"
  })
}
```

4. **Variables du module (modules/vpc/variables.tf)**
```hcl
variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "tags" {
  description = "A map of tags to assign to the resource"
  type        = map(string)
  default     = {}
}
```

5. **Sorties du module (modules/vpc/outputs.tf)**
```hcl
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}
```

6. **Configuration racine (terragrunt.hcl)**
```hcl
locals {
  common_tags = {
    Project   = "formation-terragrunt"
    ManagedBy = "terragrunt"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
EOF
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket         = "terraform-states-formation-terragrunt"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

---

7. **Configuration environnement dev**
```hcl
# environments/dev/account.hcl
locals {
  account_name = "dev"
  aws_region   = "eu-west-1"
  
  environment_tags = {
    Environment = "development"
  }
}
```

```hcl
# environments/dev/vpc/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

terraform {
  source = "../../../modules//vpc"
}

inputs = {
  aws_region = local.account_vars.locals.aws_region
  vpc_name   = "vpc-${local.account_vars.locals.account_name}"
  vpc_cidr   = "10.0.0.0/16"
  
  tags = merge(
    local.account_vars.locals.environment_tags,
    {
      Name = "vpc-${local.account_vars.locals.account_name}"
    }
  )
}
```

#### Test du TP
```bash
# Navigation vers l'environnement dev
cd environments/dev/vpc

# Plan Terraform
terragrunt plan

# Application (si bucket S3 configuré)
terragrunt apply
```
