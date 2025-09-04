# Exercice Terragrunt - Chaîne de Dépendances avec Hooks (45 minutes)

## 🎯 Objectif
Créer une infrastructure complète AWS avec hooks Terragrunt pour gérer les dépendances : VPC → Security Groups → RDS → EC2

## 📋 Prérequis
- AWS CLI configuré
- Terragrunt installé
- Terraform installé
- Accès AWS avec permissions appropriées

## 🏗️ Architecture Cible
```
VPC (10.0.0.0/16)
├── Public Subnet (10.0.1.0/24)
├── Private Subnet (10.0.2.0/24)
├── Internet Gateway
└── NAT Gateway
    │
    ├── Security Groups
    │   ├── Web SG (HTTP/HTTPS)
    │   └── DB SG (MySQL)
    │
    ├── RDS MySQL (Private)
    └── EC2 Web Server (Public)
```

## Phase 1 : Configuration Root et VPC

### 1.1 Structure des dossiers
```
exercice1/
├── terragrunt.hcl                 # Configuration root
├── vpc/
│   └── terragrunt.hcl
├── security-groups/
│   └── terragrunt.hcl
├── database/
│   └── terragrunt.hcl
└── web-servers/
    └── terragrunt.hcl
```

### 1.2 Configuration Root (`terragrunt.hcl`)
```hcl
# Configuration globale pour tous les modules
locals {
  # Variables communes
  aws_region = "eu-west-1"
  environment = "dev"
  project_name = "hooks-exercise"
  
  # Tags par défaut
  common_tags = {
    Environment = local.environment
    Project     = local.project_name
    ManagedBy   = "terragrunt"
  }
}

# Configuration AWS provider
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
  region = "${local.aws_region}"
  
  default_tags {
    tags = ${jsonencode(local.common_tags)}
  }
}
EOF
}

# Configuration du backend S3
remote_state {
  backend = "s3"
  config = {
    bucket = "your-terragrunt-state-bucket"  # À adapter
    key    = "${path_relative_to_include()}/terraform.tfstate"
    region = "eu-west-1"
    
    dynamodb_table = "terragrunt-locks"
    encrypt        = true
  }
}

# Hooks globaux
terraform {
  before_hook "validate_aws" {
    commands = ["plan", "apply"]
    execute  = ["aws", "sts", "get-caller-identity"]
  }
  
  after_hook "notify_completion" {
    commands = ["apply"]
    execute  = ["echo", "✅ Deployment completed for ${path_relative_to_include()}"]
  }
}
```

### 1.3 VPC Configuration (`vpc/terragrunt.hcl`)
```hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=v5.0.0"
}

locals {
  vpc_cidr = "10.0.0.0/16"
}

# Hook de validation avant création
terraform {
  before_hook "check_cidr" {
    commands = ["plan", "apply"]
    execute = ["echo", "🔍 Validating VPC CIDR: ${local.vpc_cidr}"]
  }
  
  after_hook "export_outputs" {
    commands = ["apply"]
    execute = ["echo", "📤 VPC created successfully, outputs will be available for dependent modules"]
  }
}

inputs = {
  name = "hooks-exercise-vpc"
  cidr = local.vpc_cidr
  
  azs             = ["eu-west-1a", "eu-west-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.4.0/24"]
  
  enable_nat_gateway = true
  enable_vpn_gateway = false
  enable_dns_hostnames = true
  enable_dns_support = true
  
  tags = {
    Name = "hooks-exercise-vpc"
  }
}
```

---

## Phase 2 : Security Groups avec Hooks (10 minutes)

### 2.1 Security Groups (`security-groups/terragrunt.hcl`)
```hcl
include "root" {
  path = find_in_parent_folders()
}

# Dépendance explicite au VPC
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-fake"
  }
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git//modules/http-80?ref=v4.0.0"
}

# Hook de vérification des dépendances
terraform {
  before_hook "check_dependencies" {
    commands = ["plan", "apply"]
    execute = ["echo", "🔗 Checking VPC dependency: ${dependency.vpc.outputs.vpc_id}"]
  }
  
  before_hook "validate_vpc_exists" {
    commands = ["plan", "apply"]
    execute = [
      "aws", "ec2", "describe-vpcs", 
      "--vpc-ids", "${dependency.vpc.outputs.vpc_id}",
      "--query", "Vpcs[0].VpcId",
      "--output", "text"
    ]
  }
  
  after_hook "list_security_groups" {
    commands = ["apply"]
    execute = [
      "aws", "ec2", "describe-security-groups",
      "--filters", "Name=vpc-id,Values=${dependency.vpc.outputs.vpc_id}",
      "--query", "SecurityGroups[].{Name:GroupName,ID:GroupId}",
      "--output", "table"
    ]
  }
}

# Configuration multi-modules pour créer plusieurs security groups
inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id
  
  # Web Security Group
  web_security_group = {
    name        = "hooks-exercise-web-sg"
    description = "Security group for web servers"
    
    ingress_rules = [
      {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        description = "HTTP"
      },
      {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        description = "HTTPS"
      },
      {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["10.0.0.0/16"]
        description = "SSH from VPC"
      }
    ]
    
    egress_rules = [
      {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        description = "All outbound"
      }
    ]
  }
  
  # Database Security Group
  database_security_group = {
    name        = "hooks-exercise-db-sg"
    description = "Security group for RDS database"
    
    ingress_rules = [
      {
        from_port   = 3306
        to_port     = 3306
        protocol    = "tcp"
        cidr_blocks = ["10.0.0.0/16"]
        description = "MySQL from VPC"
      }
    ]
  }
}
```

---

## Phase 3 : RDS et EC2 avec Dépendances (15 minutes)

### 3.1 Database RDS (`database/terragrunt.hcl`)
```hcl
include "root" {
  path = find_in_parent_folders()
}

# Dépendances multiples
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-fake"
    private_subnets = ["subnet-fake1", "subnet-fake2"]
  }
}

dependency "security_groups" {
  config_path = "../security-groups"
  mock_outputs = {
    database_security_group_id = "sg-fake"
  }
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds.git?ref=v6.0.0"
}

# Hooks spécifiques à RDS
terraform {
  before_hook "check_subnets" {
    commands = ["plan", "apply"]
    execute = ["echo", "🗄️ Preparing RDS deployment in subnets: ${join(",", dependency.vpc.outputs.private_subnets)}"]
  }
  
  before_hook "validate_security_group" {
    commands = ["plan", "apply"]
    execute = [
      "aws", "ec2", "describe-security-groups",
      "--group-ids", "${dependency.security_groups.outputs.database_security_group_id}",
      "--query", "SecurityGroups[0].GroupId",
      "--output", "text"
    ]
  }
  
  after_hook "test_connectivity" {
    commands = ["apply"]
    execute = ["echo", "🔌 RDS instance created. Test connectivity from EC2 instances in the same VPC."]
  }
  
  error_hook "cleanup_on_error" {
    commands = ["apply"]
    execute = ["echo", "❌ RDS deployment failed. Check AWS console for detailed error information."]
  }
}

inputs = {
  identifier = "hooks-exercise-db"
  
  engine               = "mysql"
  engine_version       = "8.0"
  family              = "mysql8.0"
  major_engine_version = "8.0"
  instance_class      = "db.t3.micro"
  
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = false  # Pour simplifier l'exercice
  
  db_name  = "exercisedb"
  username = "admin"
  password = "changeme123!"  # En production, utiliser AWS Secrets Manager
  port     = 3306
  
  multi_az               = false
  db_subnet_group_name   = null  # Sera créé automatiquement
  vpc_security_group_ids = [dependency.security_groups.outputs.database_security_group_id]
  subnet_ids            = dependency.vpc.outputs.private_subnets
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  deletion_protection = false  # Pour faciliter la suppression dans l'exercice
  
  tags = {
    Name = "hooks-exercise-database"
  }
}
```

### 3.2 Web Servers EC2 (`web-servers/terragrunt.hcl`)
```hcl
include "root" {
  path = find_in_parent_folders()
}

# Dépendances vers tous les modules précédents
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-fake"
    public_subnets = ["subnet-fake1", "subnet-fake2"]
  }
}

dependency "security_groups" {
  config_path = "../security-groups"
  mock_outputs = {
    web_security_group_id = "sg-fake"
  }
}

dependency "database" {
  config_path = "../database"
  mock_outputs = {
    db_instance_endpoint = "fake-endpoint.region.rds.amazonaws.com"
  }
  skip_outputs = true  # Optionnel si la DB n'est pas critique pour le plan
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ec2-instance.git?ref=v5.0.0"
}

# Hooks avancés pour EC2
terraform {
  before_hook "prepare_user_data" {
    commands = ["plan", "apply"]
    execute = [
      "bash", "-c", <<-EOT
        echo "🚀 Preparing EC2 user data script..."
        echo "Database endpoint: ${dependency.database.outputs.db_instance_endpoint}"
        echo "Security group: ${dependency.security_groups.outputs.web_security_group_id}"
      EOT
    ]
  }
  
  before_hook "check_ami" {
    commands = ["plan", "apply"]
    execute = [
      "aws", "ec2", "describe-images",
      "--owners", "amazon",
      "--filters", "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2",
      "--query", "Images | sort_by(@, &CreationDate) | [-1].ImageId",
      "--output", "text"
    ]
  }
  
  after_hook "test_instance" {
    commands = ["apply"]
    execute = ["echo", "🌐 EC2 instance deployed. Testing web server connectivity..."]
  }
  
  after_hook "display_endpoints" {
    commands = ["apply"]
    execute = [
      "bash", "-c", <<-EOT
        echo "=== 📋 DEPLOYMENT SUMMARY ==="
        echo "Web Server URL: http://\$(terraform output -raw public_ip)"
        echo "Database Endpoint: ${dependency.database.outputs.db_instance_endpoint}"
        echo "VPC ID: ${dependency.vpc.outputs.vpc_id}"
        echo "=========================="
      EOT
    ]
  }
}

# Data source pour récupérer la dernière AMI Amazon Linux 2
locals {
  user_data = base64encode(<<-EOT
    #!/bin/bash
    yum update -y
    yum install -y httpd mysql
    systemctl start httpd
    systemctl enable httpd
    
    # Page web simple avec info sur la DB
    cat > /var/www/html/index.html << 'HTML'
    <!DOCTYPE html>
    <html>
    <head>
        <title>Hooks Exercise - Web Server</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; background: #f4f4f4; }
            .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
            h1 { color: #333; }
            .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 20px 0; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🎉 Terragrunt Hooks Exercise Successful!</h1>
            <div class="info">
                <h3>Infrastructure Details:</h3>
                <p><strong>Database Endpoint:</strong> ${dependency.database.outputs.db_instance_endpoint}</p>
                <p><strong>VPC ID:</strong> ${dependency.vpc.outputs.vpc_id}</p>
                <p><strong>Deployed with:</strong> Terragrunt + Terraform</p>
                <p><strong>Instance ID:</strong> $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
            </div>
            <p>This web server was deployed using a complete dependency chain managed by Terragrunt hooks!</p>
        </div>
    </body>
    </html>
HTML
  EOT
  )
}

inputs = {
  name = "hooks-exercise-web"
  
  ami           = "ami-0c02fb55956c7d316"  # Amazon Linux 2 (à adapter selon la région)
  instance_type = "t2.micro"
  key_name      = "your-key-pair"  # À adapter
  
  vpc_security_group_ids = [dependency.security_groups.outputs.web_security_group_id]
  subnet_id             = dependency.vpc.outputs.public_subnets[0]
  
  associate_public_ip_address = true
  
  user_data_base64 = local.user_data
  
  root_block_device = [
    {
      volume_type = "gp3"
      volume_size = 10
      encrypted   = false
    }
  ]
  
  tags = {
    Name = "hooks-exercise-web-server"
    Type = "WebServer"
  }
}
```

---

## Phase 4 : Tests et Validation (10 minutes)

### 4.1 Script de déploiement (`deploy.sh`)
```bash
#!/bin/bash

set -e

echo "🚀 Starting Terragrunt Hooks Exercise Deployment"
echo "=================================================="

# Variables
MODULES=("vpc" "security-groups" "database" "web-servers")
ROOT_DIR="exercice1"

# Fonction de déploiement avec gestion d'erreurs
deploy_module() {
    local module=$1
    echo ""
    echo "📦 Deploying $module..."
    echo "------------------------"
    
    cd "$ROOT_DIR/$module"
    
    # Hooks en action
    echo "🔄 Running terragrunt plan for $module..."
    terragrunt plan
    
    echo "✅ Running terragrunt apply for $module..."
    terragrunt apply -auto-approve
    
    cd - > /dev/null
    
    echo "✅ $module deployed successfully!"
}

# Déploiement séquentiel avec gestion des dépendances
for module in "${MODULES[@]}"; do
    deploy_module "$module"
done

echo ""
echo "🎉 All modules deployed successfully!"
echo "🌐 Check the web server URL in the final output"

# Test final
echo ""
echo "🧪 Running final tests..."
cd "$ROOT_DIR/web-servers"
WEB_IP=$(terragrunt output -raw public_ip)
echo "Testing web server at: http://$WEB_IP"
curl -s "http://$WEB_IP" | grep -q "Hooks Exercise" && echo "✅ Web server test passed!" || echo "❌ Web server test failed"
```

### 4.2 Script de nettoyage (`destroy.sh`)
```bash
#!/bin/bash

set -e

echo "🧹 Destroying Terragrunt Hooks Exercise Infrastructure"
echo "====================================================="

# Destruction dans l'ordre inverse
MODULES=("web-servers" "database" "security-groups" "vpc")
ROOT_DIR="exercice1"

for module in "${MODULES[@]}"; do
    echo ""
    echo "🗑️ Destroying $module..."
    cd "$ROOT_DIR/$module"
    terragrunt destroy -auto-approve
    cd - > /dev/null
    echo "✅ $module destroyed!"
done

echo ""
echo "🎉 All infrastructure destroyed successfully!"
```

### 4.3 Points de validation
- [ ] VPC créé avec subnets publics et privés
- [ ] Security Groups créés avec bonnes règles
- [ ] RDS déployé dans subnet privé
- [ ] EC2 accessible via IP publique
- [ ] Page web affiche les informations d'infrastructure
- [ ] Hooks s'exécutent correctement à chaque étape
- [ ] Dépendances respectées dans l'ordre

## 🎯 Critères de Réussite
1. **Hooks fonctionnels** : Tous les hooks s'exécutent sans erreur
2. **Dépendances respectées** : Modules déployés dans le bon ordre
3. **Infrastructure opérationnelle** : Web server accessible avec page d'accueil
4. **Sécurité** : Database accessible uniquement depuis le VPC
5. **Nettoyage** : Destruction complète possible

## 🚀 Extensions Possibles
- Ajouter un Load Balancer
- Implémenter des hooks de notification (Slack/Teams)
- Utiliser AWS Systems Manager pour les secrets
- Ajouter des hooks de tests automatisés
- Intégrer un pipeline CI/CD

## 📚 Points Clés Appris
- Gestion des dépendances avec Terragrunt
- Utilisation des hooks pour automation
- Validation et tests intégrés
- Gestion des erreurs dans les hooks
- Structure modulaire d'infrastructure