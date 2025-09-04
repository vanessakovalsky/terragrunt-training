# Exercice Terragrunt - Gestion des Modules, DRY et Environnements
**Durée : 90 minutes**

## Objectifs pédagogiques
À l'issue de cet exercice, vous serez capable de :
- Structurer un projet Terragrunt multi-environnements
- Appliquer le principe DRY (Don't Repeat Yourself) avec Terragrunt
- Gérer des modules Terraform réutilisables
- Configurer des environnements avec des paramètres spécifiques
- Utiliser les fonctionnalités avancées de Terragrunt (dependencies, hooks, etc.)

## Prérequis
- Terraform installé (version 1.0+)
- Terragrunt installé (version 0.45+)
- AWS CLI configuré avec des credentials valides
- Connaissances de base en Terraform

## Contexte du projet
Vous devez déployer une infrastructure web simple sur AWS avec :
- Un VPC avec subnets publics et privés
- Un groupe de sécurité
- Des instances EC2
- Un Load Balancer
- 3 environnements : dev, staging, prod

---

## Phase 1 : Préparation de la structure (15 minutes)

### Étape 1.1 : Créer l'arborescence du projet

```
terragrunt-workshop/
├── modules/
│   ├── vpc/
│   ├── security-group/
│   ├── ec2/
│   └── load-balancer/
├── environments/
│   ├── dev/
│   ├── staging/
│   └── prod/
├── terragrunt.hcl (racine)
└── README.md
```

**Action :** Créez cette structure de dossiers

### Étape 1.2 : Fichier terragrunt.hcl racine

Créez le fichier `terragrunt.hcl` à la racine :

```hcl
# Configuration globale pour tous les environnements
remote_state {
  backend = "s3"
  
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  
  config = {
    bucket         = "votre-nom-terragrunt-state-${get_env("USER", "default")}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "terragrunt-locks"
  }
}

# Configuration du provider AWS
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
}

provider "aws" {
  region = var.aws_region
}
EOF
}

# Variables communes à tous les environnements
inputs = {
  project_name = "terragrunt-workshop"
}
```

---

## Phase 2 : Création des modules Terraform (25 minutes)

### Étape 2.1 : Module VPC

**Fichier :** `modules/vpc/main.tf`

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-vpc"
    Environment = var.environment
    Project     = var.project_name
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-igw"
    Environment = var.environment
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-public-${count.index + 1}"
    Environment = var.environment
    Type        = "public"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "${var.project_name}-${var.environment}-private-${count.index + 1}"
    Environment = var.environment
    Type        = "private"
  }
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-public-rt"
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

**Fichier :** `modules/vpc/outputs.tf`

```hcl
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}
```

### Étape 2.2 : Module Security Group

**Fichier :** `modules/security-group/main.tf`

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "allowed_ports" {
  description = "List of allowed ports"
  type        = list(number)
  default     = [80, 443, 22]
}

resource "aws_security_group" "web" {
  name        = "${var.project_name}-${var.environment}-web-sg"
  description = "Security group for web servers"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.allowed_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-sg"
    Environment = var.environment
  }
}
```

**Fichier :** `modules/security-group/outputs.tf`

```hcl
output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.web.id
}
```

### Étape 2.3 : Module EC2

**Fichier :** `modules/ec2/main.tf`

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "instance_count" {
  description = "Number of instances"
  type        = number
  default     = 2
}

variable "subnet_ids" {
  description = "List of subnet IDs"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs"
  type        = list(string)
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "web" {
  count                  = var.instance_count
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  security_groups        = var.security_group_ids
  
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from ${var.environment} - Instance ${count.index + 1}</h1>" > /var/www/html/index.html
              EOF

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-${count.index + 1}"
    Environment = var.environment
  }
}
```

**Fichier :** `modules/ec2/outputs.tf`

```hcl
output "instance_ids" {
  description = "IDs of the EC2 instances"
  value       = aws_instance.web[*].id
}

output "instance_ips" {
  description = "Public IPs of the EC2 instances"
  value       = aws_instance.web[*].public_ip
}
```

---

## Phase 3 : Configuration des environnements avec Terragrunt (30 minutes)

### Étape 3.1 : Configuration commune des environnements

**Fichier :** `environments/terragrunt.hcl`

```hcl
# Configuration partagée par tous les environnements
locals {
  # Lire les variables d'environnement depuis un fichier YAML
  env_vars = yamldecode(file("${get_terragrunt_dir()}/env.yaml"))
  
  # Configuration commune
  common_tags = {
    Project     = "terragrunt-workshop"
    ManagedBy   = "terragrunt"
    Environment = local.env_vars.environment
  }
}

# Variables communes
inputs = merge(
  local.env_vars,
  {
    project_name = "terragrunt-workshop"
    common_tags  = local.common_tags
  }
)
```

### Étape 3.2 : Configuration de l'environnement DEV

**Fichier :** `environments/dev/env.yaml`

```yaml
environment: dev
aws_region: eu-west-1
vpc_cidr: "10.10.0.0/16"
availability_zones:
  - "eu-west-1a"
  - "eu-west-1b"
public_subnet_cidrs:
  - "10.10.1.0/24"
  - "10.10.2.0/24"
private_subnet_cidrs:
  - "10.10.11.0/24"
  - "10.10.12.0/24"
instance_type: "t3.micro"
instance_count: 1
allowed_ports: [80, 22]
```

**Fichier :** `environments/dev/terragrunt.hcl`

```hcl
# Inclure la configuration racine
include "root" {
  path = find_in_parent_folders()
}

# Inclure la configuration commune des environnements
include "env" {
  path = "${get_terragrunt_dir()}/../terragrunt.hcl"
}

# Configuration locale
locals {
  env_vars = yamldecode(file("env.yaml"))
}

# Dépendances entre modules
dependencies {
  paths = []
}

# Configuration Terraform
terraform {
  source = "../..//."
}

# Module VPC
dependency "vpc" {
  config_path = "./vpc"
}

# Module Security Group
dependency "security_group" {
  config_path = "./security-group"
}

# Inputs spécifiques
inputs = merge(
  local.env_vars,
  {
    # Variables spécifiques à dev si nécessaire
  }
)
```

### Étape 3.3 : Modules pour l'environnement DEV

**Fichier :** `environments/dev/vpc/terragrunt.hcl`

```hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/vpc"
}

inputs = {
  environment             = "dev"
  vpc_cidr               = "10.10.0.0/16"
  availability_zones     = ["eu-west-1a", "eu-west-1b"]
  public_subnet_cidrs    = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs   = ["10.10.11.0/24", "10.10.12.0/24"]
}
```

**Fichier :** `environments/dev/security-group/terragrunt.hcl`

```hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/security-group"
}

dependency "vpc" {
  config_path = "../vpc"
  
  mock_outputs = {
    vpc_id = "vpc-fake-id"
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment   = "dev"
  vpc_id        = dependency.vpc.outputs.vpc_id
  allowed_ports = [80, 22]
}
```

**Fichier :** `environments/dev/ec2/terragrunt.hcl`

```hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/ec2"
}

dependency "vpc" {
  config_path = "../vpc"
  
  mock_outputs = {
    public_subnet_ids = ["subnet-fake-1", "subnet-fake-2"]
  }
}

dependency "security_group" {
  config_path = "../security-group"
  
  mock_outputs = {
    security_group_id = "sg-fake-id"
  }
}

inputs = {
  environment        = "dev"
  instance_type      = "t3.micro"
  instance_count     = 1
  subnet_ids         = dependency.vpc.outputs.public_subnet_ids
  security_group_ids = [dependency.security_group.outputs.security_group_id]
}
```

### Étape 3.4 : Configuration STAGING

**Fichier :** `environments/staging/env.yaml`

```yaml
environment: staging
aws_region: eu-west-1
vpc_cidr: "10.20.0.0/16"
availability_zones:
  - "eu-west-1a"
  - "eu-west-1b"
public_subnet_cidrs:
  - "10.20.1.0/24"
  - "10.20.2.0/24"
private_subnet_cidrs:
  - "10.20.11.0/24"
  - "10.20.12.0/24"
instance_type: "t3.small"
instance_count: 2
allowed_ports: [80, 443, 22]
```

**Action :** Créez les fichiers terragrunt.hcl pour staging en adaptant les configurations de dev.

### Étape 3.5 : Configuration PROD

**Fichier :** `environments/prod/env.yaml`

```yaml
environment: prod
aws_region: eu-west-1
vpc_cidr: "10.30.0.0/16"
availability_zones:
  - "eu-west-1a"
  - "eu-west-1b"
  - "eu-west-1c"
public_subnet_cidrs:
  - "10.30.1.0/24"
  - "10.30.2.0/24"
  - "10.30.3.0/24"
private_subnet_cidrs:
  - "10.30.11.0/24"
  - "10.30.12.0/24"
  - "10.30.13.0/24"
instance_type: "t3.medium"
instance_count: 3
allowed_ports: [80, 443]
```

---

## Phase 4 : Déploiement et tests (15 minutes)

### Étape 4.1 : Préparation du state backend

```bash
# Créer le bucket S3 pour le state (remplacez par votre nom unique)
aws s3 mb s3://votre-nom-terragrunt-state-${USER}

# Créer la table DynamoDB pour les locks
aws dynamodb create-table \
  --table-name terragrunt-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

### Étape 4.2 : Déploiement de l'environnement DEV

```bash
cd environments/dev

# Planifier tous les modules
terragrunt run-all plan

# Déployer tous les modules
terragrunt run-all apply --terragrunt-non-interactive

# Vérifier les outputs
terragrunt run-all output
```

### Étape 4.3 : Tests et validation

```bash
# Tester la connectivité aux instances
# Récupérer les IPs des instances depuis les outputs
cd environments/dev/ec2
terragrunt output instance_ips

# Tester l'accès web (remplacez par l'IP réelle)
curl http://INSTANCE_IP
```

---

## A vous de jouer

* Préparer les fichiers pour l'environnement de stagging et de prod et deployer les avec terragrunt


---

## Questions de validation

1. **DRY** : Comment Terragrunt évite-t-il la duplication de code entre environnements ?
2. **Dependencies** : Quel est l'avantage des dépendances entre modules ?
3. **State management** : Pourquoi utilise-t-on des backends distants ?
4. **Hooks** : Donnez deux cas d'usage pour les hooks Terragrunt
5. **Mock outputs** : Dans quels cas utilise-t-on les mock outputs ?

---

## Nettoyage

```bash
# Détruire l'infrastructure dev
cd environments/dev
terragrunt run-all destroy --terragrunt-non-interactive

# Supprimer le bucket S3 et la table DynamoDB si nécessaire
aws s3 rb s3://votre-nom-terragrunt-state-${USER} --force
aws dynamodb delete-table --table-name terragrunt-locks --region eu-west-1
```

---

## Ressources supplémentaires

- [Documentation officielle Terragrunt](https://terragrunt.gruntwork.io/)
- [Best practices Terraform](https://www.terraform.io/docs/cloud/guides/recommended-practices/index.html)
- [Patterns de structuration](https://github.com/gruntwork-io/terragrunt-infrastructure-live-example)

## Exercices supplémentaires (bonus)

### Exercice A : Gestion des secrets
1. Intégrez AWS Systems Manager Parameter Store pour gérer les secrets
2. Utilisez `sops` pour chiffrer les fichiers de configuration sensibles

### Exercice B : Multi-région
1. Adaptez la configuration pour déployer sur plusieurs régions AWS
2. Gérez la réplication des données entre régions

### Exercice C : Monitoring et logging
1. Ajoutez un module CloudWatch pour le monitoring
2. Configurez des alertes automatiques
