### 🛠️ TP : Déploiement multi-environnements complet

#### Objectif
Déployer une architecture 3-tiers (Web/App/DB) sur 3 environnements avec configuration centralisée et gestion des dépendances.

#### Architecture cible
```
Internet
    ↓
[Load Balancer] ← Certificat SSL
    ↓
[Web Tier] ← Auto Scaling Group  
    ↓
[App Tier] ← Auto Scaling Group
    ↓
[Database] ← RDS Multi-AZ (prod only)
```

#### Structure du projet
```
formation-tp2/
├── root.hcl                    # Configuration globale
├── _envcommon/                       # Configurations centralisées
│   ├── networking.hcl               # VPC, subnets, routes
│   ├── security.hcl                 # Security groups, NACLs
│   ├── compute.hcl                  # EC2, Auto Scaling
│   ├── database.hcl                 # RDS configuration
│   └── loadbalancer.hcl             # ALB configuration
├── _common/
│   ├── naming.hcl                   # Standards de nommage
│   └── tagging.hcl                  # Standards de tags
├── modules/                          # Modules Terraform
│   ├── vpc/
│   ├── security-groups/
│   ├── alb/
│   ├── asg/
│   ├── rds/
│   └── iam/
└── environments/
    ├── dev/
    │   ├── account.hcl              # Config compte dev
    │   ├── region.hcl               # Config région
    │   ├── 01-networking/
    │   │   └── terragrunt.hcl       # VPC + Subnets
    │   ├── 02-security/
    │   │   └── terragrunt.hcl       # Security Groups
    │   ├── 03-database/
    │   │   └── terragrunt.hcl       # RDS instance
    │   ├── 04-compute/
    │   │   └── terragrunt.hcl       # Auto Scaling Groups
    │   └── 05-loadbalancer/
    │       └── terragrunt.hcl       # Application Load Balancer
    ├── staging/
    └── prod/
```

#### 1. Configuration globale (terragrunt.hcl)
```hcl
locals {
  # Variables globales du projet
  project_config = {
    organization = "mycompany"
    project      = "webapp"
    
    # Standards de tagging
    common_tags = {
      Organization = "MyCompany"
      Project      = "WebApp"
      ManagedBy    = "Terragrunt"
      Repository   = "https://github.com/mycompany/webapp-infrastructure"
    }
    
    # Configuration de sécurité globale
    security_standards = {
      tls_version = "1.2"
      encryption_at_rest = true
      backup_retention_min = 7
      log_retention_days = 30
    }
  }
}

# Configuration backend commune
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket = "terraform-states-webapp-${get_aws_account_id()}"
    key    = "${path_relative_to_include()}/terraform.tfstate"
    region = "eu-west-1"
    encrypt = true
    dynamodb_table = "terraform-locks-webapp"
    
    tags = merge(local.project_config.common_tags, {
      Component = "terraform-state"
    })
  }
}

# Configuration Terraform commune
terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    
    env_vars = {
      TF_VAR_common_tags = jsonencode(local.project_config.common_tags)
    }
  }
  
  # Arguments additionnels pour les plans
  extra_arguments "plan_args" {
    commands = ["plan"]
    arguments = [
      "-out=tfplan"
    ]
  }
}
```

#### 2. Configuration environnement dev
```hcl
# environments/dev/account.hcl
locals {
  account_id   = "123456789012"
  account_name = "dev"
  
  # Configuration spécifique dev
  env_config = {
    # Sizing économique pour le développement
    instance_types = {
      web = "t3.micro"
      app = "t3.small"
      db  = "db.t3.micro"
    }
    
    # Configuration allégée
    min_instances = 1
    max_instances = 2
    multi_az = false
    backup_retention = 1
    
    # Configuration réseau
    cidr_block = "10.0.0.0/16"
    availability_zones = ["eu-west-1a", "eu-west-1b"]
    
    # Variables applicatives
    app_config = {
      log_level = "DEBUG"
      cache_size = "128MB"
      worker_processes = 2
    }
    
    # Budget et alertes
    cost_budget = {
      daily_limit = 20
      monthly_limit = 400
    }
  }
  
  # Tags spécifiques à l'environnement
  env_tags = {
    Environment = "development"
    CostCenter  = "engineering"
    AutoShutdown = "yes"
    Owner       = "dev-team"
  }
}
```

#### 3. Configuration networking centralisée
```hcl
# _envcommon/networking.hcl
locals {
  # Variables de l'environnement
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  naming = read_terragrunt_config("${dirname(find_in_parent_folders())}/_common/naming.hcl").locals
  
  # Calcul automatique des subnets
  vpc_cidr = local.account_vars.locals.env_config.cidr_block
  az_count = length(local.account_vars.locals.env_config.availability_zones)
  
  # Subnets publics (pour ALB)
  public_subnets = [
    for i in range(local.az_count) :
    cidrsubnet(local.vpc_cidr, 8, i + 1)
  ]
  
  # Subnets privés (pour instances)
  private_subnets = [
    for i in range(local.az_count) :
    cidrsubnet(local.vpc_cidr, 8, i + 10)
  ]
  
  # Subnets database
  database_subnets = [
    for i in range(local.az_count) :
    cidrsubnet(local.vpc_cidr, 8, i + 20)
  ]
}

terraform {
  source = "${dirname(find_in_parent_folders())}//modules/vpc"
}

# Pas de dépendances pour le networking
dependency "account" {
  config_path = "../account"
  skip_outputs = true
}

inputs = {
  # Configuration VPC
  vpc_name = format(
    "%s-%s-vpc",
    local.naming.naming_convention.org_prefix.company,
    local.account_vars.locals.account_name
  )
  
  cidr_block = local.vpc_cidr
  
  # Configuration des subnets
  availability_zones = local.account_vars.locals.env_config.availability_zones
  public_subnets = local.public_subnets
  private_subnets = local.private_subnets  
  database_subnets = local.database_subnets
  
  # Configuration NAT Gateway
  enable_nat_gateway = true
  single_nat_gateway = local.account_vars.locals.account_name != "prod"  # Single NAT en non-prod
  
  # Configuration DNS
  enable_dns_hostnames = true
  enable_dns_support = true
  
  # Tags
  tags = merge(
    local.account_vars.locals.env_tags,
    {
      Component = "networking"
      Tier      = "infrastructure"
    }
  )
}
```

#### 4. Configuration database avec dépendances
```hcl
# _envcommon/database.hcl
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  naming = read_terragrunt_config("${dirname(find_in_parent_folders())}/_common/naming.hcl").locals
}

terraform {
  source = "${dirname(find_in_parent_folders())}//modules/rds"
}

# Dépendance sur le networking et la sécurité
dependency "networking" {
  config_path = "../01-networking"
  
  mock_outputs = {
    vpc_id = "vpc-mock"
    database_subnet_group_name = "mock-db-subnet-group"
  }
}

dependency "security" {
  config_path = "../02-security"
  
  mock_outputs = {
    database_security_group_id = "sg-mock"
  }
}

inputs = {
  # Configuration de l'instance
  identifier = format(
    "%s-%s-db",
    local.naming.naming_convention.org_prefix.company,
    local.account_vars.locals.account_name
  )
  
  # Configuration technique
  engine = "postgres"
  engine_version = "13.7"
  instance_class = local.account_vars.locals.env_config.instance_types.db
  allocated_storage = local.account_vars.locals.account_name == "prod" ? 100 : 20
  max_allocated_storage = local.account_vars.locals.account_name == "prod" ? 1000 : 100
  
  # Configuration réseau
  db_subnet_group_name = dependency.networking.outputs.database_subnet_group_name
  vpc_security_group_ids = [dependency.security.outputs.database_security_group_id]
  
  # Configuration haute disponibilité
  multi_az = local.account_vars.locals.env_config.multi_az
  
  # Configuration de sauvegarde
  backup_retention_period = local.account_vars.locals.env_config.backup_retention
  backup_window = "03:00-04:00"
  maintenance_window = "sun:04:00-sun:05:00"
  
  # Configuration de monitoring
  monitoring_interval = local.account_vars.locals.account_name == "prod" ? 60 : 0
  performance_insights_enabled = local.account_vars.locals.account_name != "dev"
  
  # Paramètres de base de données
  database_name = "webapp"
  username = "webapp_admin"
  
  # Chiffrement
  storage_encrypted = true
  
  # Tags
  tags = merge(
    local.account_vars.locals.env_tags,
    {
      Component = "database"
      Tier      = "data"
      Engine    = "postgres"
    }
  )
}
```

#### 5. Configuration compute avec dépendances multiples
```hcl
# _envcommon/compute.hcl
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  naming = read_terragrunt_config("${dirname(find_in_parent_folders())}/_common/naming.hcl").locals
}

terraform {
  source = "${dirname(find_in_parent_folders())}//modules/asg"
}

# Dépendances sur networking, security et database
dependency "networking" {
  config_path = "../01-networking"
  
  mock_outputs = {
    vpc_id = "vpc-mock"
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
  }
}

dependency "security" {
  config_path = "../02-security"
  
  mock_outputs = {
    app_security_group_id = "sg-mock"
  }
}

dependency "database" {
  config_path = "../03-database"
  
  mock_outputs = {
    database_endpoint = "mock.rds.amazonaws.com"
    database_port = "5432"
  }
}

inputs = {
  # Configuration Launch Template
  name_prefix = format(
    "%s-%s-app",
    local.naming.naming_convention.org_prefix.company,
    local.account_vars.locals.account_name
  )
  
  # Configuration instance
  instance_type = local.account_vars.locals.env_config.instance_types.app
  
  # Configuration réseau
  vpc_id = dependency.networking.outputs.vpc_id
  subnet_ids = dependency.networking.outputs.private_subnet_ids
  security_group_ids = [dependency.security.outputs.app_security_group_id]
  
  # Configuration Auto Scaling
  min_size = local.account_vars.locals.env_config.min_instances
  max_size = local.account_vars.locals.env_config.max_instances
  desired_capacity = local.account_vars.locals.env_config.min_instances
  
  # Configuration de l'application
  user_data = base64encode(templatefile(
    "${dirname(find_in_parent_folders())}/templates/app_userdata.sh.tpl",
    {
      environment = local.account_vars.locals.account_name
      database_endpoint = dependency.database.outputs.database_endpoint
      database_port = dependency.database.outputs.database_port
      log_level = local.account_vars.locals.env_config.app_config.log_level
      cache_size = local.account_vars.locals.env_config.app_config.cache_size
    }
  ))
  
  # Health check
  health_check_type = "ELB"
  health_check_grace_period = 300
  
  # Tags
  tags = merge(
    local.account_vars.locals.env_tags,
    {
      Component = "application"
      Tier      = "compute"
    }
  )
  
  # Tags pour les instances
  instance_tags = merge(
    local.account_vars.locals.env_tags,
    {
      Name = format(
        "%s-%s-app-instance",
        local.naming.naming_convention.org_prefix.company,
        local.account_vars.locals.account_name
      )
    }
  )
}
```

#### 6. Script de déploiement automatisé
```bash
#!/bin/bash
# deploy.sh - Script de déploiement multi-environnements

set -e

# Configuration
ENVIRONMENTS=("dev" "staging" "prod")
COMPONENTS=("01-networking" "02-security" "03-database" "04-compute" "05-loadbalancer")

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction d'affichage
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Fonction de déploiement d'un composant
deploy_component() {
    local env=$1
    local component=$2
    local action=$3
    
    local component_path="environments/${env}/${component}"
    
    log "Déploiement de ${component} pour l'environnement ${env}"
    
    if [ ! -d "$component_path" ]; then
        warning "Le composant ${component} n'existe pas pour l'environnement ${env}"
        return 0
    fi
    
    cd "$component_path"
    
    # Validation de la configuration
    log "Validation de la configuration..."
    terragrunt validate
    
    # Plan
    log "Génération du plan..."
    terragrunt plan -out=tfplan
    
    # Application si demandée
    if [ "$action" == "apply" ]; then
        log "Application du plan..."
        terragrunt apply tfplan
        success "Composant ${component} déployé avec succès"
    else
        success "Plan généré avec succès pour ${component}"
    fi
    
    cd - > /dev/null
}

# Fonction de déploiement d'un environnement complet
deploy_environment() {
    local env=$1
    local action=$2
    
    log "=== Déploiement de l'environnement ${env} ==="
    
    # Vérification de l'environnement
    if [[ ! " ${ENVIRONMENTS[@]} " =~ " ${env} " ]]; then
        error "Environnement invalide: ${env}"
        error "Environnements disponibles: ${ENVIRONMENTS[*]}"
        exit 1
    fi
    
    # Déploiement séquentiel des composants
    for component in "${COMPONENTS[@]}"; do
        deploy_component "$env" "$component" "$action"
        
        # Pause entre les composants pour éviter les conflits
        if [ "$action" == "apply" ]; then
            log "Attente de 10 secondes avant le composant suivant..."
            sleep 10
        fi
    done
    
    success "=== Environnement ${env} déployé avec succès ==="
}

# Fonction de déploiement de tous les environnements
deploy_all() {
    local action=$1
    
    log "=== Déploiement de tous les environnements ==="
    
    for env in "${ENVIRONMENTS[@]}"; do
        deploy_environment "$env" "$action"
        
        if [ "$action" == "apply" ]; then
            log "Attente de 30 secondes avant l'environnement suivant..."
            sleep 30
        fi
    done
    
    success "=== Tous les environnements déployés ==="
}

# Fonction de destruction
destroy_environment() {
    local env=$1
    
    warning "=== DESTRUCTION de l'environnement ${env} ==="
    read -p "Êtes-vous sûr de vouloir détruire l'environnement ${env}? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "Destruction annulée"
        return 0
    fi
    
    # Destruction dans l'ordre inverse
    local reversed_components=($(printf '%s\n' "${COMPONENTS[@]}" | tac))
    
    for component in "${reversed_components[@]}"; do
        local component_path="environments/${env}/${component}"
        
        if [ -d "$component_path" ]; then
            log "Destruction de ${component} pour l'environnement ${env}"
            cd "$component_path"
            terragrunt destroy -auto-approve
            cd - > /dev/null
            success "Composant ${component} détruit"
        fi
    done
    
    success "=== Environnement ${env} détruit ==="
}

# Fonction d'affichage de l'aide
show_help() {
    cat << EOF
Usage: $0 [COMMAND] [ENVIRONMENT] [OPTIONS]

Commands:
    plan ENV        Génère le plan pour un environnement
    apply ENV       Déploie un environnement
    destroy ENV     Détruit un environnement
    plan-all        Génère les plans pour tous les environnements
    apply-all       Déploie tous les environnements
    status          Affiche le status de tous les environnements

Environments:
    dev             Environnement de développement
    staging         Environnement de staging
    prod            Environnement de production

Examples:
    $0 plan dev              # Plan pour dev
    $0 apply prod            # Déploiement en production
    $0 destroy staging       # Destruction du staging
    $0 apply-all             # Déploiement de tous les environnements

EOF
}

# Fonction de status
show_status() {
    log "=== Status des environnements ==="
    
    for env in "${ENVIRONMENTS[@]}"; do
        log "Environnement: ${env}"
        
        for component in "${COMPONENTS[@]}"; do
            local component_path="environments/${env}/${component}"
            
            if [ -d "$component_path" ]; then
                cd "$component_path"
                
                # Vérification de l'état Terraform
                if terragrunt show > /dev/null 2>&1; then
                    success "  ${component}: Déployé"
                else
                    warning "  ${component}: Non déployé"
                fi
                
                cd - > /dev/null
            else
                warning "  ${component}: Non configuré"
            fi
        done
        echo ""
    done
}

# Script principal
main() {
    case "$1" in
        "plan")
            if [ -z "$2" ]; then
                error "Environment requis pour la commande plan"
                show_help
                exit 1
            fi
            deploy_environment "$2" "plan"
            ;;
        "apply")
            if [ -z "$2" ]; then
                error "Environment requis pour la commande apply"
                show_help
                exit 1
            fi
            deploy_environment "$2" "apply"
            ;;
        "destroy")
            if [ -z "$2" ]; then
                error "Environment requis pour la commande destroy"
                show_help
                exit 1
            fi
            destroy_environment "$2"
            ;;
        "plan-all")
            deploy_all "plan"
            ;;
        "apply-all")
            deploy_all "apply"
            ;;
        "status")
            show_status
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            error "Commande invalide: $1"
            show_help
            exit 1
            ;;
    esac
}

# Vérification des prérequis
check_prerequisites() {
    local missing_tools=()
    
    # Vérification de terragrunt
    if ! command -v terragrunt &> /dev/null; then
        missing_tools+=("terragrunt")
    fi
    
    # Vérification de terraform
    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi
    
    # Vérification d'AWS CLI
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Outils manquants: ${missing_tools[*]}"
        error "Veuillez installer les outils requis"
        exit 1
    fi
    
    # Vérification de la configuration AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        error "Configuration AWS invalide ou manquante"
        error "Veuillez configurer vos credentials AWS"
        exit 1
    fi
}

# Point d'entrée
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

check_prerequisites
main "$@"
```

#### 7. Template user data pour les instances
```bash
# templates/app_userdata.sh.tpl
#!/bin/bash

# Configuration des variables
ENVIRONMENT="${environment}"
DATABASE_ENDPOINT="${database_endpoint}"
DATABASE_PORT="${database_port}"
LOG_LEVEL="${log_level}"
CACHE_SIZE="${cache_size}"

# Logs d'installation
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Début de l'installation - $(date) ==="
echo "Environnement: $ENVIRONMENT"

# Mise à jour du système
yum update -y

# Installation des dépendances
yum install -y \
    docker \
    amazon-cloudwatch-agent \
    aws-cli \
    htop \
    vim

# Démarrage de Docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Configuration CloudWatch Agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/webapp/app.log",
            "log_group_name": "/aws/ec2/webapp-$ENVIRONMENT",
            "log_stream_name": "{instance_id}/app.log"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/aws/ec2/webapp-$ENVIRONMENT",
            "log_stream_name": "{instance_id}/user-data.log"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "WebApp/$ENVIRONMENT",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_iowait"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  }
}
EOF

# Démarrage de CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s

# Création du répertoire de l'application
mkdir -p /opt/webapp/logs
chown ec2-user:ec2-user /opt/webapp -R

# Configuration de l'application
cat > /opt/webapp/.env << EOF
ENVIRONMENT=$ENVIRONMENT
DATABASE_HOST=$DATABASE_ENDPOINT
DATABASE_PORT=$DATABASE_PORT
LOG_LEVEL=$LOG_LEVEL
CACHE_SIZE=$CACHE_SIZE
EOF

# Script de démarrage de l'application
cat > /opt/webapp/start.sh << 'EOF'
#!/bin/bash
cd /opt/webapp

# Chargement des variables d'environnement
source .env

# Démarrage de l'application (exemple avec Docker)
docker run -d \
    --name webapp-$ENVIRONMENT \
    --restart unless-stopped \
    -p 8080:8080 \
    -v /opt/webapp/logs:/app/logs \
    -e ENVIRONMENT=$ENVIRONMENT \
    -e DATABASE_HOST=$DATABASE_HOST \
    -e DATABASE_PORT=$DATABASE_PORT \
    -e LOG_LEVEL=$LOG_LEVEL \
    -e CACHE_SIZE=$CACHE_SIZE \
    mycompany/webapp:latest

echo "Application démarrée - $(date)"
EOF

chmod +x /opt/webapp/start.sh

# Configuration du service systemd
cat > /etc/systemd/system/webapp.service << EOF
[Unit]
Description=Web Application
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/webapp/start.sh
ExecStop=/usr/bin/docker stop webapp-$ENVIRONMENT
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webapp
systemctl start webapp

# Installation de l'agent de monitoring
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm

echo "=== Installation terminée - $(date) ==="
```

#### 8. Tests de validation post-déploiement
```bash
#!/bin/bash
# validate.sh - Script de validation des déploiements

# Configuration
ENVIRONMENTS=("dev" "staging" "prod")

# Fonction de test de connectivité
test_connectivity() {
    local env=$1
    local endpoint=$2
    local port=$3
    
    echo "Test de connectivité vers $endpoint:$port pour $env..."
    
    if timeout 10 bash -c "</dev/tcp/$endpoint/$port"; then
        echo "✅ Connectivité OK"
        return 0
    else
        echo "❌ Connectivité KO"
        return 1
    fi
}

# Fonction de test de l'application
test_application() {
    local env=$1
    local alb_dns=$2
    
    echo "Test de l'application pour $env..."
    
    # Test de la page d'accueil
    local response=$(curl -s -o /dev/null -w "%{http_code}" "http://$alb_dns/health")
    
    if [ "$response" = "200" ]; then
        echo "✅ Application répond correctement"
        return 0
    else
        echo "❌ Application ne répond pas (Code: $response)"
        return 1
    fi
}

# Fonction de test de la base de données
test_database() {
    local env=$1
    local db_endpoint=$2
    
    echo "Test de la base de données pour $env..."
    
    # Récupération des informations de connexion depuis AWS
    local db_info=$(aws rds describe-db-instances \
        --db-instance-identifier "mycompany-$env-db" \
        --query 'DBInstances[0].{Endpoint:Endpoint.Address,Status:DBInstanceStatus}' \
        --output json)
    
    local db_status=$(echo $db_info | jq -r '.Status')
    
    if [ "$db_status" = "available" ]; then
        echo "✅ Base de données disponible"
        return 0
    else
        echo "❌ Base de données indisponible (Status: $db_status)"
        return 1
    fi
}

# Fonction de validation complète d'un environnement
validate_environment() {
    local env=$1
    echo "=== Validation de l'environnement $env ==="
    
    local errors=0
    
    # Récupération des outputs Terragrunt
    cd "environments/$env/05-loadbalancer"
    local alb_dns=$(terragrunt output -raw alb_dns_name 2>/dev/null)
    cd - > /dev/null
    
    cd "environments/$env/03-database"
    local db_endpoint=$(terragrunt output -raw database_endpoint 2>/dev/null)
    cd - > /dev/null
    
    # Tests
    if [ -n "$alb_dns" ]; then
        test_application "$env" "$alb_dns" || ((errors++))
    else
        echo "❌ Load Balancer DNS non trouvé"
        ((errors++))
    fi
    
    if [ -n "$db_endpoint" ]; then
        test_database "$env" "$db_endpoint" || ((errors++))
        test_connectivity "$env" "$db_endpoint" "5432" || ((errors++))
    else
        echo "❌ Database endpoint non trouvé"
        ((errors++))
    fi
    
    if [ $errors -eq 0 ]; then
        echo "✅ Environnement $env validé avec succès"
        return 0
    else
        echo "❌ Environnement $env a $errors erreur(s)"
        return 1
    fi
}

# Script principal
main() {
    local env=$1
    local total_errors=0
    
    if [ -n "$env" ]; then
        # Validation d'un environnement spécifique
        validate_environment "$env" || ((total_errors++))
    else
        # Validation de tous les environnements
        for env in "${ENVIRONMENTS[@]}"; do
            validate_environment "$env" || ((total_errors++))
            echo ""
        done
    fi
    
    if [ $total_errors -eq 0 ]; then
        echo "🎉 Toutes les validations sont passées avec succès"
        exit 0
    else
        echo "💥 $total_errors environnement(s) ont des erreurs"
        exit 1
    fi
}

main "$@"
```
