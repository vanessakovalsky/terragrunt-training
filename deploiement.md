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

#### 1. Configuration globale (root.hcl)
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
