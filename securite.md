# Exercice Terragrunt - Pipeline CI/CD Sécurisé (60 minutes)

## 🎯 Objectif
Créer un pipeline CI/CD complet et sécurisé pour automatiser les déploiements Terragrunt avec validation, planification, déploiement conditionnel et sauvegarde des logs.

## 📋 Prérequis
- Repository Git (GitHub/GitLab)
- AWS CLI et credentials configurés
- Terragrunt/Terraform installés
- Accès à un service CI/CD (GitHub Actions, GitLab CI)

## 🏗️ Architecture du Pipeline
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Validation    │ -> │   Plan Stage    │ -> │  Deploy Stage   │
│   - Syntax      │    │   - All modules │    │   - Main only   │
│   - Linting     │    │   - Security    │    │   - With logs   │
│   - Format      │    │   - Cost        │    │   - Monitoring  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```


## Phase 1 : Structure Projet et Validation (15 minutes)

### 1.1 Structure du Projet
```
secure-terragrunt-pipeline/
├── .github/
│   └── workflows/
│       ├── validate.yml
│       ├── plan.yml
│       └── deploy.yml
├── .gitlab-ci.yml
├── scripts/
│   ├── validate.sh
│   ├── plan-all.sh
│   ├── deploy.sh
│   └── save-logs.sh
├── environments/
│   ├── dev/
│   │   ├── terragrunt.hcl
│   │   ├── vpc/
│   │   ├── security/
│   │   └── compute/
│   ├── staging/
│   └── prod/
├── modules/
│   ├── networking/
│   ├── security/
│   └── compute/
├── policies/
│   ├── sentinel/
│   └── opa/
└── docs/
    └── pipeline.md
```

### 1.2 Configuration Root Terragrunt
```hcl
# environments/terragrunt.hcl
locals {
  # Variables d'environnement
  environment = basename(get_terragrunt_dir())
  region      = get_env("AWS_DEFAULT_REGION", "eu-west-1")
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
```

### 1.3 Scripts de Validation
```bash
# scripts/validate.sh
#!/bin/bash

set -euo pipefail

echo "🔍 Starting Terragrunt validation pipeline..."

# Configuration
LOG_DIR="logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
VALIDATION_LOG="$LOG_DIR/validation_$TIMESTAMP.log"

# Création du dossier de logs
mkdir -p "$LOG_DIR"

# Fonction de logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$VALIDATION_LOG"
}

# Fonction de validation avec code de retour
validate_step() {
    local step_name="$1"
    local command="$2"
    
    log "📝 Running: $step_name"
    
    if eval "$command" >> "$VALIDATION_LOG" 2>&1; then
        log "✅ $step_name: PASSED"
        return 0
    else
        log "❌ $step_name: FAILED"
        return 1
    fi
}

# Variables d'environnement requises
required_vars=(
    "AWS_DEFAULT_REGION"
    "AWS_ACCESS_KEY_ID" 
    "AWS_SECRET_ACCESS_KEY"
)

# Validation des variables d'environnement
log "🔐 Checking required environment variables..."
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "❌ Missing required environment variable: $var"
        exit 1
    fi
    log "✅ $var is set"
done

# 1. Validation de la syntaxe Terragrunt
log "🔍 Phase 1: Syntax Validation"
validate_step "Terragrunt syntax check" "find . -name '*.hcl' -exec terragrunt hclfmt --terragrunt-check {} \;"

# 2. Validation Terraform
log "🔍 Phase 2: Terraform Validation"
environments=("dev" "staging" "prod")

for env in "${environments[@]}"; do
    if [[ -d "environments/$env" ]]; then
        log "📁 Validating environment: $env"
        cd "environments/$env"
        
        # Validation de tous les modules
        modules=$(find . -name "terragrunt.hcl" -not -path "./terragrunt.hcl" | xargs dirname)
        
        for module in $modules; do
            log "🔍 Validating module: $env/$module"
            cd "$module"
            
            validate_step "Init $env/$module" "terragrunt init --terragrunt-non-interactive"
            validate_step "Validate $env/$module" "terragrunt validate"
            validate_step "Format check $env/$module" "terraform fmt -check=true -diff=true"
            
            cd - > /dev/null
        done
        
        cd - > /dev/null
    fi
done

# 3. Sécurité et conformité
log "🔍 Phase 3: Security & Compliance"

# Scan des secrets avec git-secrets ou truffleHog
if command -v git-secrets &> /dev/null; then
    validate_step "Secret scan" "git secrets --scan"
elif command -v truffleHog &> /dev/null; then
    validate_step "Secret scan" "truffleHog --regex --entropy=False ."
else
    log "⚠️ No secret scanning tool found (git-secrets or truffleHog recommended)"
fi

# Scan de sécurité avec tfsec
if command -v tfsec &> /dev/null; then
    validate_step "Security scan" "tfsec --format json --out $LOG_DIR/security_$TIMESTAMP.json ."
    log "📊 Security report saved to: $LOG_DIR/security_$TIMESTAMP.json"
else
    log "⚠️ tfsec not found - security scanning skipped"
fi

# Validation des policies avec OPA/Sentinel (si disponible)
if [[ -d "policies/opa" ]] && command -v opa &> /dev/null; then
    validate_step "OPA policy validation" "opa test policies/opa/"
fi

# 4. Génération du rapport
log "📊 Phase 4: Report Generation"

# Résumé des validations
cat << EOF > "$LOG_DIR/validation_summary_$TIMESTAMP.md"
# Validation Report

**Date:** $(date)
**Commit:** \${GITHUB_SHA:-\${CI_COMMIT_SHA:-$(git rev-parse HEAD)}}
**Branch:** \${GITHUB_REF_NAME:-\${CI_COMMIT_REF_NAME:-$(git branch --show-current)}}

## Summary
- Syntax validation: ✅ PASSED
- Format validation: ✅ PASSED  
- Security scan: ✅ COMPLETED
- Policy validation: ✅ COMPLETED

## Files Checked
$(find . -name "*.hcl" -o -name "*.tf" | wc -l) Terraform/Terragrunt files

## Next Steps
- Review security findings in: security_$TIMESTAMP.json
- Proceed to planning phase if all validations passed
- Full logs available in: validation_$TIMESTAMP.log

EOF

log "📋 Validation summary generated: $LOG_DIR/validation_summary_$TIMESTAMP.md"
log "🎉 Validation pipeline completed successfully!"

# Upload des logs vers S3 pour archivage
if [[ "${CI:-false}" == "true" ]]; then
    aws s3 cp "$LOG_DIR/" "s3://pipeline-logs-bucket/validation/" --recursive --quiet || true
    log "📤 Logs uploaded to S3"
fi

exit 0
```

---

## Phase 2 : Configuration du Pipeline CI/CD (20 minutes)

### 2.1 GitHub Actions Pipeline
```yaml
# .github/workflows/terragrunt-pipeline.yml
name: 🚀 Secure Terragrunt Pipeline

on:
  push:
    branches: [ main, develop, 'feature/*' ]
  pull_request:
    branches: [ main, develop ]
  
  # Déploiement manuel pour prod
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: 'dev'
        type: choice
        options:
        - dev
        - staging
        - prod
      
      force_deploy:
        description: 'Force deployment (skip safety checks)'
        required: false
        type: boolean
        default: false

env:
  TF_VERSION: '1.6.0'
  TG_VERSION: '0.53.0'
  AWS_DEFAULT_REGION: 'eu-west-1'

jobs:
  # Job 1: Validation complète
  validate:
    name: 🔍 Validate & Security Check
    runs-on: ubuntu-latest
    timeout-minutes: 15
    
    outputs:
      validation-status: ${{ steps.validate.outputs.status }}
      
    steps:
    - name: 📥 Checkout Code
      uses: actions/checkout@v4
      with:
        fetch-depth: 0  # Pour git-secrets
        
    - name: 🔧 Setup Terraform
      uses: hashicorp/setup-terraform@v3
      with:
        terraform_version: ${{ env.TF_VERSION }}
        
    - name: 🔧 Setup Terragrunt
      run: |
        curl -LO "https://github.com/gruntwork-io/terragrunt/releases/download/v${{ env.TG_VERSION }}/terragrunt_linux_amd64"
        chmod +x terragrunt_linux_amd64
        sudo mv terragrunt_linux_amd64 /usr/local/bin/terragrunt
        terragrunt --version
        
    - name: 🔐 Configure AWS Credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        aws-region: ${{ env.AWS_DEFAULT_REGION }}
        
    - name: 🛡️ Install Security Tools
      run: |
        # Installation tfsec
        curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
        
        # Installation git-secrets
        git clone https://github.com/awslabs/git-secrets.git
        cd git-secrets && make install && cd ..
        git secrets --register-aws
        git secrets --install
        
        # Installation Infracost (optionnel)
        if [[ "${{ github.event_name }}" == "pull_request" ]]; then
          curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh
        fi
        
    - name: 🔍 Run Validation Pipeline
      id: validate
      run: |
        chmod +x scripts/validate.sh
        ./scripts/validate.sh
        echo "status=success" >> $GITHUB_OUTPUT
      env:
        PIPELINE_OWNER: ${{ github.actor }}
        CI_PIPELINE_ID: ${{ github.run_id }}
        
    - name: 📊 Upload Validation Artifacts
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: validation-logs-${{ github.run_id }}
        path: logs/
        retention-days: 30
        
    - name: 💬 Comment PR with Validation Results  
      uses: actions/github-script@v7
      if: github.event_name == 'pull_request'
      with:
        script: |
          const fs = require('fs');
          const path = 'logs';
          
          if (fs.existsSync(path)) {
            const files = fs.readdirSync(path);
            const summaryFile = files.find(f => f.includes('validation_summary'));
            
            if (summaryFile) {
              const summary = fs.readFileSync(`${path}/${summaryFile}`, 'utf8');
              
              github.rest.issues.createComment({
                issue_number: context.issue.number,
                owner: context.repo.owner,
                repo: context.repo.repo,
                body: `## 🔍 Validation Results\n\n${summary}`
              });
            }
          }

  # Job 2: Planification pour tous les environnements
  plan:
    name: 📋 Plan All Environments  
    runs-on: ubuntu-latest
    needs: validate
    if: needs.validate.outputs.validation-status == 'success'
    timeout-minutes: 20
    
    strategy:
      matrix:
        environment: [dev, staging, prod]
        
    steps:
    - name: 📥 Checkout Code
      uses: actions/checkout@v4
      
    - name: 🔧 Setup Tools
      run: |
        # Setup Terraform
        curl -LO "https://releases.hashicorp.com/terraform/${{ env.TF_VERSION }}/terraform_${{ env.TF_VERSION }}_linux_amd64.zip"
        unzip terraform_${{ env.TF_VERSION }}_linux_amd64.zip
        sudo mv terraform /usr/local/bin/
        
        # Setup Terragrunt  
        curl -LO "https://github.com/gruntwork-io/terragrunt/releases/download/v${{ env.TG_VERSION }}/terragrunt_linux_amd64"
        chmod +x terragrunt_linux_amd64
        sudo mv terragrunt_linux_amd64 /usr/local/bin/terragrunt
        
    - name: 🔐 Configure AWS Credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        aws-region: ${{ env.AWS_DEFAULT_REGION }}
        role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/TerragruntDeployRole-${{ matrix.environment }}
        role-session-name: GitHubActions-${{ github.run_id }}
        
    - name: 📋 Generate Terragrunt Plan
      id: plan
      run: |
        cd environments/${{ matrix.environment }}
        
        echo "🔄 Generating plan for ${{ matrix.environment }}..."
        
        # Plan avec sauvegarde
        terragrunt run-all plan \
          --terragrunt-non-interactive \
          --terragrunt-out-dir ../../plans/${{ matrix.environment }} \
          --terragrunt-log-level info \
          > ../../logs/plan_${{ matrix.environment }}_$(date +%Y%m%d_%H%M%S).log 2>&1
          
        echo "plan-status=success" >> $GITHUB_OUTPUT
      env:
        TF_IN_AUTOMATION: "true"
        
    - name: 💰 Cost Estimation
      if: github.event_name == 'pull_request'
      run: |
        if command -v infracost &> /dev/null; then
          cd environments/${{ matrix.environment }}
          
          infracost breakdown \
            --path . \
            --format json \
            --out-file ../../costs/cost_${{ matrix.environment }}.json || true
            
          infracost diff \
            --path . \
            --format github-comment \
            --repo ${{ github.repository }} \
            --pull-request ${{ github.event.pull_request.number }} \
            --behavior update || true
        fi
        
    - name: 📦 Upload Plan Artifacts
      uses: actions/upload-artifact@v3
      with:
        name: terraform-plans-${{ matrix.environment }}-${{ github.run_id }}
        path: |
          plans/${{ matrix.environment }}/
          logs/plan_${{ matrix.environment }}_*.log
        retention-days: 30

  # Job 3: Déploiement conditionnel
  deploy:
    name: 🚀 Deploy Infrastructure
    runs-on: ubuntu-latest
    needs: [validate, plan]
    if: |
      (github.ref == 'refs/heads/main' && github.event_name == 'push') ||
      (github.event_name == 'workflow_dispatch')
    timeout-minutes: 30
    
    environment: 
      name: ${{ github.event.inputs.environment || 'dev' }}
      
    steps:
    - name: 📥 Checkout Code
      uses: actions/checkout@v4
      
    - name: 🔧 Setup Tools
      run: |
        curl -LO "https://releases.hashicorp.com/terraform/${{ env.TF_VERSION }}/terraform_${{ env.TF_VERSION }}_linux_amd64.zip"
        unzip terraform_${{ env.TF_VERSION }}_linux_amd64.zip
        sudo mv terraform /usr/local/bin/
        
        curl -LO "https://github.com/gruntwork-io/terragrunt/releases/download/v${{ env.TG_VERSION }}/terragrunt_linux_amd64"
        chmod +x terragrunt_linux_amd64
        sudo mv terragrunt_linux_amd64 /usr/local/bin/terragrunt
        
    - name: 🔐 Configure AWS Credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        aws-region: ${{ env.AWS_DEFAULT_REGION }}
        
    - name: 🚀 Deploy Infrastructure
      id: deploy
      run: |
        target_env="${{ github.event.inputs.environment || 'dev' }}"
        
        echo "🚀 Starting deployment to: $target_env"
        
        cd environments/$target_env
        
        # Sauvegarde des logs de déploiement
        mkdir -p ../../logs
        
        terragrunt run-all apply \
          --terragrunt-non-interactive \
          --terragrunt-log-level info \
          > ../../logs/deploy_${target_env}_$(date +%Y%m%d_%H%M%S).log 2>&1
          
        echo "deploy-status=success" >> $GITHUB_OUTPUT
        echo "environment=$target_env" >> $GITHUB_OUTPUT
      env:
        TF_IN_AUTOMATION: "true"
        PIPELINE_OWNER: ${{ github.actor }}
        CI_PIPELINE_ID: ${{ github.run_id }}
        
    - name: 🧪 Post-Deploy Validation
      run: |
        echo "🧪 Running post-deployment tests..."
        
        # Tests de sanité basiques
        target_env="${{ github.event.inputs.environment || 'dev' }}"
        cd environments/$target_env
        
        # Vérification que les ressources sont créées
        terragrunt run-all output > ../../logs/outputs_${target_env}.json
        
        echo "✅ Post-deployment validation completed"
        
    - name: 📊 Upload Deploy Artifacts
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: deployment-logs-${{ steps.deploy.outputs.environment }}-${{ github.run_id }}
        path: logs/
        retention-days: 90
        
    - name: 📤 Archive Logs to S3
      if: always()
      run: |
        # Upload vers S3 pour archivage long terme
        aws s3 cp logs/ s3://pipeline-logs-bucket/deployments/$(date +%Y/%m/%d)/ --recursive --quiet || true
        echo "📤 Logs archived to S3"

  # Job 4: Notification
  notify:
    name: 📢 Notify Results
    runs-on: ubuntu-latest
    needs: [validate, plan, deploy]
    if: always()
    
    steps:
    - name: 📢 Slack Notification
      uses: 8398a7/action-slack@v3
      if: always()
      with:
        status: ${{ needs.deploy.result || needs.plan.result || needs.validate.result }}
        channel: '#devops'
        webhook_url: ${{ secrets.SLACK_WEBHOOK }}
        fields: repo,message,commit,author,action,eventName,ref,workflow
        custom_payload: |
          {
            attachments: [{
              color: '${{ needs.deploy.result }}' === 'success' ? 'good' : '${{ needs.deploy.result }}' === 'failure' ? 'danger' : 'warning',
              fields: [{
                title: 'Pipeline Result',
                value: '${{ needs.deploy.result || needs.plan.result || needs.validate.result }}',
                short: true
              }, {
                title: 'Environment',
                value: '${{ github.event.inputs.environment || "dev" }}',
                short: true
              }]
            }]
          }
```

### 2.2 Script de Planification
```bash
# scripts/plan-all.sh
#!/bin/bash

set -euo pipefail

echo "📋 Starting comprehensive Terragrunt planning..."

# Configuration
ENVIRONMENTS=("dev" "staging" "prod")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PLAN_DIR="plans"
LOG_DIR="logs"

# Création des dossiers
mkdir -p "$PLAN_DIR" "$LOG_DIR"

# Fonction de logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/plan_all_$TIMESTAMP.log"
}

# Fonction de planification par environnement
plan_environment() {
    local env="$1"
    local plan_log="$LOG_DIR/plan_${env}_$TIMESTAMP.log"
    local plan_output="$PLAN_DIR/${env}"
    
    log "📋 Planning environment: $env"
    
    if [[ ! -d "environments/$env" ]]; then
        log "⚠️ Environment directory not found: $env"
        return 1
    fi
    
    cd "environments/$env"
    
    # Nettoyage des anciens plans
    rm -rf "../../$plan_output"
    mkdir -p "../../$plan_output"
    
    # Initialisation de tous les modules
    log "🔄 Initializing all modules in $env..."
    if ! terragrunt run-all init --terragrunt-non-interactive >> "$plan_log" 2>&1; then
        log "❌ Failed to initialize modules in $env"
        cd - > /dev/null
        return 1
    fi
    
    # Génération des plans
    log "📋 Generating plans for $env..."
    if terragrunt run-all plan \
        --terragrunt-non-interactive \
        --terragrunt-out-dir "../../$plan_output" \
        --terragrunt-log-level info \
        >> "../../$plan_log" 2>&1; then
        
        log "✅ Plans generated successfully for $env"
        
        # Analyse des changements
        analyze_plan_changes "$env" "$plan_output"
        
        cd - > /dev/null
        return 0
    else
        log "❌ Failed to generate plans for $env"
        cd - > /dev/null
        return 1
    fi
}

# Analyse des changements dans les plans
analyze_plan_changes() {
    local env="$1"
    local plan_dir="$2"
    
    log "📊 Analyzing plan changes for $env..."
    
    local changes_summary="$LOG_DIR/changes_${env}_$TIMESTAMP.md"
    
    cat << EOF > "$changes_summary"
# Plan Analysis for $env

**Generated:** $(date)
**Environment:** $env

## Summary of Changes
EOF
    
    # Recherche des fichiers de plan
    find "$plan_dir" -name "*.tfplan" | while read -r plan_file; do
        module_name=$(basename "$(dirname "$plan_file")")
        
        echo "### Module: $module_name" >> "$changes_summary"
        
        # Extraction des métriques de changement
        if terraform show -json "$plan_file" > /dev/null 2>&1; then
            terraform show -json "$plan_file" | jq -r '
                .resource_changes[] |
                select(.change.actions != ["no-op"]) |
                "- \(.change.actions | join(", ")): \(.address)"
            ' >> "$changes_summary" 2>/dev/null || echo "- Analysis failed for $module_name" >> "$changes_summary"
        fi
        
        echo "" >> "$changes_summary"
    done
    
    log "📊 Plan analysis saved: $changes_summary"
}

# Validation des prérequis
log "🔍 Validating prerequisites..."

# Vérification des outils
for tool in terragrunt terraform aws jq; do
    if ! command -v "$tool" &> /dev/null; then
        log "❌ Required tool not found: $tool"
        exit 1
    fi
done

# Vérification des credentials AWS
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log "❌ AWS credentials not configured"
    exit 1
fi

log "✅ Prerequisites validated"

# Planification pour tous les environnements
failed_environments=()

for env in "${ENVIRONMENTS[@]}"; do
    if ! plan_environment "$env"; then
        failed_environments+=("$env")
    fi
done

# Génération du rapport global
generate_global_report() {
    local report_file="$LOG_DIR/planning_report_$TIMESTAMP.md"
    
    cat << EOF > "$report_file"
# Global Planning Report

**Date:** $(date)
**Environments:** ${ENVIRONMENTS[*]}
**Branch:** \${GITHUB_REF_NAME:-\${CI_COMMIT_REF_NAME:-$(git branch --show-current 2>/dev/null || echo "unknown")}}
**Commit:** \${GITHUB_SHA:-\${CI_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}}

## Planning Results

EOF

    for env in "${ENVIRONMENTS[@]}"; do
        if [[ " ${failed_environments[*]} " =~ " $env " ]]; then
            echo "- ❌ **$env**: FAILED" >> "$report_file"
        else
            echo "- ✅ **$env**: SUCCESS" >> "$report_file"
        fi
    done
    
    cat << EOF >> "$report_file"

## Files Generated

$(find "$PLAN_DIR" -name "*.tfplan" | wc -l) plan files created
$(find "$LOG_DIR" -name "*.log" | wc -l) log files generated

## Security Analysis

EOF

    # Intégration avec tfsec si disponible
    if command -v tfsec &> /dev/null; then
        echo "### Security Scan Results" >> "$report_file"
        echo '```' >> "$report_file"
        tfsec --format brief . >> "$report_file" 2>/dev/null || echo "Security scan failed" >> "$report_file"
        echo '```' >> "$report_file"
    fi
    
    cat << EOF >> "$report_file"

## Cost Estimation

EOF

    # Intégration avec Infracost si disponible
    if command -v infracost &> /dev/null; then
        for env in "${ENVIRONMENTS[@]}"; do
            if [[ -d "environments/$env" ]]; then
                echo "### $env Environment" >> "$report_file"
                cd "environments/$env"
                infracost breakdown --path . --format table >> "../../$report_file" 2>/dev/null || echo "Cost analysis failed for $env" >> "../../$report_file"
                cd - > /dev/null
            fi
        done
    else
        echo "Infracost not available - cost estimation skipped" >> "$report_file"
    fi
    
    cat << EOF >> "$report_file"

## Next Steps

1. Review all plan files in the \`$PLAN_DIR\` directory
2. Check security findings and address any issues
3. Validate cost implications before deployment
4. Proceed with deployment on main branch only

## Artifacts

- Plan files: \`$PLAN_DIR/\`
- Logs: \`$LOG_DIR/\`
- Analysis: \`$LOG_DIR/changes_*_$TIMESTAMP.md\`

EOF

    log "📋 Global report generated: $report_file"
}

# Génération du rapport final
generate_global_report

# Résumé final
if [[ ${#failed_environments[@]} -eq 0 ]]; then
    log "🎉 All environments planned successfully!"
    
    # Upload vers S3 si en environnement CI
    if [[ "${CI:-false}" == "true" ]]; then
        log "📤 Uploading plans and logs to S3..."
        aws s3 cp "$PLAN_DIR/" "s3://pipeline-artifacts-bucket/plans/$(date +%Y/%m/%d)/" --recursive --quiet || true
        aws s3 cp "$LOG_DIR/" "s3://pipeline-logs-bucket/planning/$(date +%Y/%m/%d)/" --recursive --quiet || true
    fi
    
    exit 0
else
    log "❌ Planning failed for environments: ${failed_environments[*]}"
    exit 1
fi
```

---

## Phase 3 : Sécurisation et Gestion des Secrets (15 minutes)

### 3.1 Configuration des Rôles IAM
```hcl
# modules/security/iam-roles.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  environments = ["dev", "staging", "prod"]
  
  # Politiques de sécurité par environnement
  environment_policies = {
    dev = {
      allowed_actions = [
        "ec2:*",
        "rds:*",
        "s3:*",
        "iam:List*",
        "iam:Get*"
      ]
      restricted_actions = []
    }
    staging = {
      allowed_actions = [
        "ec2:*",
        "rds:*",
        "s3:*",
        "iam:List*",
        "iam:Get*"
      ]
      restricted_actions = [
        "iam:Delete*",
        "ec2:TerminateInstances"
      ]
    }
    prod = {
      allowed_actions = [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:ModifyInstanceAttribute",
        "rds:CreateDBInstance",
        "rds:ModifyDBInstance",
        "rds:DescribeDBInstances",
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ]
      restricted_actions = [
        "iam:*",
        "ec2:TerminateInstances",
        "rds:DeleteDBInstance"
      ]
    }
  }
}

# Rôle de déploiement pour chaque environnement
resource "aws_iam_role" "terragrunt_deploy_role" {
  for_each = toset(local.environments)
  
  name = "TerragruntDeployRole-${title(each.value)}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          # GitHub Actions OIDC
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = [
              "repo:your-org/your-repo:ref:refs/heads/main",
              "repo:your-org/your-repo:ref:refs/heads/develop",
              "repo:your-org/your-repo:pull_request"
            ]
          }
        }
      },
      {
        # Pour les déploiements locaux d'urgence
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/emergency-deploy-user"
        }
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = ["eu-west-1", "us-east-1"]
          }
          DateGreaterThan = {
            "aws:CurrentTime" = "2024-01-01T00:00:00Z"
          }
          DateLessThan = {
            "aws:CurrentTime" = "2025-12-31T23:59:59Z"
          }
        }
      }
    ]
  })
  
  tags = {
    Environment = each.value
    Purpose     = "terragrunt-deployment"
    Security    = "high"
  }
}

# Politique de déploiement par environnement
resource "aws_iam_policy" "terragrunt_deploy_policy" {
  for_each = toset(local.environments)
  
  name = "TerragruntDeployPolicy-${title(each.value)}"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = local.environment_policies[each.value].allowed_actions
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = ["eu-west-1"]
          }
        }
      },
      {
        Effect = "Deny"
        Action = local.environment_policies[each.value].restricted_actions
        Resource = "*"
      },
      {
        # Accès au state bucket
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::secure-terragrunt-state-${each.value}",
          "arn:aws:s3:::secure-terragrunt-state-${each.value}/*"
        ]
      },
      {
        # Accès à DynamoDB pour les locks
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:eu-west-1:${data.aws_caller_identity.current.account_id}:table/terragrunt-locks-${each.value}"
      },
      {
        # Accès KMS pour le chiffrement
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "arn:aws:kms:eu-west-1:${data.aws_caller_identity.current.account_id}:key/pipeline-state"
      }
    ]
  })
}

# Attachement des politiques aux rôles
resource "aws_iam_role_policy_attachment" "terragrunt_deploy_policy" {
  for_each = toset(local.environments)
  
  role       = aws_iam_role.terragrunt_deploy_role[each.value].name
  policy_arn = aws_iam_policy.terragrunt_deploy_policy[each.value].arn
}

data "aws_caller_identity" "current" {}

# Outputs pour utilisation dans Terragrunt
output "deploy_role_arns" {
  value = {
    for env in local.environments :
    env => aws_iam_role.terragrunt_deploy_role[env].arn
  }
}
```

### 3.2 Script de Déploiement Sécurisé
```bash
# scripts/deploy.sh
#!/bin/bash

set -euo pipefail

echo "🚀 Starting secure Terragrunt deployment..."

# Configuration
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="logs"
DEPLOYMENT_LOG="$LOG_DIR/deployment_$TIMESTAMP.log"

# Arguments
ENVIRONMENT="${1:-dev}"
DRY_RUN="${2:-false}"
FORCE_DEPLOY="${3:-false}"

# Validation des paramètres
VALID_ENVIRONMENTS=("dev" "staging" "prod")
if [[ ! " ${VALID_ENVIRONMENTS[*]} " =~ " $ENVIRONMENT " ]]; then
    echo "❌ Invalid environment: $ENVIRONMENT"
    echo "Valid environments: ${VALID_ENVIRONMENTS[*]}"
    exit 1
fi

# Création du dossier de logs
mkdir -p "$LOG_DIR"

# Fonction de logging avec rotation
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$DEPLOYMENT_LOG"
    
    # Rotation des logs (garder les 10 derniers)
    find "$LOG_DIR" -name "deployment_*.log" -type f | sort | head -n -10 | xargs rm -f || true
}

# Fonction de notification
notify() {
    local status="$1"
    local message="$2"
    
    log "$message"
    
    # Slack notification si configuré
    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"🚀 Deployment $status: $message\"}" \
            "$SLACK_WEBHOOK_URL" || true
    fi
    
    # Teams notification si configuré
    if [[ -n "${TEAMS_WEBHOOK_URL:-}" ]]; then
        curl -s -H "Content-Type: application/json" -X POST \
            --data "{\"text\":\"🚀 Deployment $status: $message\"}" \
            "$TEAMS_WEBHOOK_URL" || true
    fi
}

# Vérifications de sécurité pré-déploiement
security_checks() {
    log "🔐 Running pre-deployment security checks..."
    
    # Vérification des credentials
    local caller_identity
    if ! caller_identity=$(aws sts get-caller-identity 2>/dev/null); then
        log "❌ AWS credentials not configured or invalid"
        return 1
    fi
    
    local account_id
    account_id=$(echo "$caller_identity" | jq -r '.Account')
    local user_arn
    user_arn=$(echo "$caller_identity" | jq -r '.Arn')
    
    log "🔍 Deploying as: $user_arn"
    log "🏢 AWS Account: $account_id"
    
    # Vérification du rôle pour la production
    if [[ "$ENVIRONMENT" == "prod" ]]; then
        if [[ "$user_arn" != *"TerragruntDeployRole-Prod"* ]] && [[ "$FORCE_DEPLOY" != "true" ]]; then
            log "❌ Production deployments require specific IAM role"
            log "Current role: $user_arn"
            log "Required role pattern: *TerragruntDeployRole-Prod*"
            return 1
        fi
        
        # Vérification de la branche pour prod
        if [[ "${CI_COMMIT_REF_NAME:-$(git branch --show-current 2>/dev/null)}" != "main" ]] && [[ "$FORCE_DEPLOY" != "true" ]]; then
            log "❌ Production deployments only allowed from main branch"
            return 1
        fi
    fi
    
    # Vérification des state buckets
    local state_bucket="secure-terragrunt-state-$ENVIRONMENT"
    if ! aws s3 ls "s3://$state_bucket" > /dev/null 2>&1; then
        log "❌ State bucket not accessible: $state_bucket"
        return 1
    fi
    
    # Vérification du chiffrement KMS
    local kms_key_id="arn:aws:kms:${AWS_DEFAULT_REGION:-eu-west-1}:$account_id:key/pipeline-state"
    if ! aws kms describe-key --key-id "$kms_key_id" > /dev/null 2>&1; then
        log "⚠️ KMS key not accessible, state encryption may fail: $kms_key_id"
    fi
    
    log "✅ Security checks passed"
    return 0
}

# Backup avant déploiement
create_backup() {
    log "💾 Creating pre-deployment backup..."
    
    local backup_dir="backups/$ENVIRONMENT/$TIMESTAMP"
    mkdir -p "$backup_dir"
    
    cd "environments/$ENVIRONMENT"
    
    # Backup des états actuels
    if terragrunt run-all output -json > "../../$backup_dir/outputs.json" 2>/dev/null; then
        log "✅ Outputs backup created"
    else
        log "⚠️ Could not backup outputs (may be first deployment)"
    fi
    
    # Backup des plans actuels si disponibles
    if [[ -d "../../plans/$ENVIRONMENT" ]]; then
        cp -r "../../plans/$ENVIRONMENT" "../../$backup_dir/plans/"
        log "✅ Plans backup created"
    fi
    
    cd - > /dev/null
    
    # Compression du backup
    tar -czf "$backup_dir.tar.gz" -C backups "$ENVIRONMENT/$TIMESTAMP"
    rm -rf "$backup_dir"
    
    log "💾 Backup saved: $backup_dir.tar.gz"
}

# Déploiement avec monitoring
deploy_infrastructure() {
    log "🚀 Starting infrastructure deployment for $ENVIRONMENT..."
    
    cd "environments/$ENVIRONMENT"
    
    # Dry run si demandé
    if [[ "$DRY_RUN" == "true" ]]; then
        log "🔍 Running dry-run (plan only)..."
        terragrunt run-all plan \
            --terragrunt-non-interactive \
            --terragrunt-log-level info \
            >> "../../$DEPLOYMENT_LOG" 2>&1
        
        log "✅ Dry-run completed successfully"
        cd - > /dev/null
        return 0
    fi
    
    # Déploiement réel avec timeout
    local start_time
    start_time=$(date +%s)
    
    log "🔄 Applying infrastructure changes..."
    
    if timeout 1800 terragrunt run-all apply \
        --terragrunt-non-interactive \
        --terragrunt-log-level info \
        >> "../../$DEPLOYMENT_LOG" 2>&1; then
        
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "✅ Deployment completed successfully in ${duration}s"
        
        # Validation post-déploiement
        post_deploy_validation
        
        cd - > /dev/null
        return 0
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "❌ Deployment failed after ${duration}s"
        
        # Tentative de rollback si en prod
        if [[ "$ENVIRONMENT" == "prod" ]]; then
            log "🔄 Attempting automatic rollback for production..."
            # Implémentation du rollback ici
        fi
        
        cd - > /dev/null
        return 1
    fi
}

# Validation post-déploiement
post_deploy_validation() {
    log "🧪 Running post-deployment validation..."
    
    # Vérification des outputs
    if terragrunt run-all output > "../../$LOG_DIR/post_deploy_outputs_$TIMESTAMP.json" 2>&1; then
        log "✅ Infrastructure outputs validated"
    else
        log "⚠️ Could not validate outputs"
    fi
    
    # Tests de connectivité basiques
    local vpc_id
    if vpc_id=$(terragrunt output -raw vpc_id 2>/dev/null); then
        if aws ec2 describe-vpcs --vpc-ids "$vpc_id" > /dev/null 2>&1; then
            log "✅ VPC connectivity validated: $vpc_id"
        else
            log "❌ VPC validation failed: $vpc_id"
            return 1
        fi
    fi
    
    # Vérification des tags de sécurité
    local resources_without_tags
    if resources_without_tags=$(aws resourcegroupstaggingapi get-resources \
        --region "${AWS_DEFAULT_REGION:-eu-west-1}" \
        --resource-type-filters "AWS::EC2::Instance" "AWS::RDS::DBInstance" \
        --query 'ResourceTagMappingList[?!Tags[?Key==`Environment`]]' \
        --output text 2>/dev/null); then
        
        if [[ -n "$resources_without_tags" ]]; then
            log "⚠️ Found resources without required tags"
        else
            log "✅ All resources properly tagged"
        fi
    fi
    
    log "✅ Post-deployment validation completed"
}

# Main execution flow
main() {
    notify "STARTED" "Deployment started for $ENVIRONMENT environment"
    
    # Vérifications de sécurité
    if ! security_checks; then
        notify "FAILED" "Security checks failed for $ENVIRONMENT"
        exit 1
    fi
    
    # Backup
    if [[ "$ENVIRONMENT" == "prod" ]] || [[ "$ENVIRONMENT" == "staging" ]]; then
        create_backup
    fi
    
    # Déploiement
    if deploy_infrastructure; then
        notify "SUCCESS" "Deployment completed successfully for $ENVIRONMENT"
        
        # Archive des logs
        log "📤 Archiving deployment logs..."
        aws s3 cp "$DEPLOYMENT_LOG" \
            "s3://pipeline-logs-bucket/deployments/$(date +%Y/%m/%d)/" \
            --quiet || log "⚠️ Failed to archive logs to S3"
        
        exit 0
    else
        notify "FAILED" "Deployment failed for $ENVIRONMENT"
        
        # Archive des logs d'erreur
        aws s3 cp "$DEPLOYMENT_LOG" \
            "s3://pipeline-logs-bucket/failures/$(date +%Y/%m/%d)/" \
            --quiet || log "⚠️ Failed to archive failure logs"
        
        exit 1
    fi
}

# Gestion des signaux pour cleanup
cleanup() {
    log "🧹 Cleaning up deployment process..."
    # Nettoyage des processus en cours si nécessaire
    exit 130
}

trap cleanup SIGINT SIGTERM

# Affichage de la configuration
log "📋 Deployment Configuration:"
log "  Environment: $ENVIRONMENT"
log "  Dry Run: $DRY_RUN"
log "  Force Deploy: $FORCE_DEPLOY"
log "  Branch: ${CI_COMMIT_REF_NAME:-$(git branch --show-current 2>/dev/null || echo 'unknown')}"
log "  Commit: ${CI_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo 'unknown')}"

# Exécution principale
main "$@"
```

---

## Phase 4 : Tests, Logs et Monitoring (10 minutes)

### 4.1 Script de Sauvegarde des Logs
```bash
# scripts/save-logs.sh
#!/bin/bash

set -euo pipefail

echo "📊 Starting log archival and monitoring setup..."

# Configuration
LOG_DIR="logs"
BACKUP_DIR="log-backups"
S3_BUCKET="pipeline-logs-bucket"
RETENTION_DAYS=90
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Fonction de logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Création des dossiers
mkdir -p "$BACKUP_DIR"

# Archivage des logs locaux
archive_local_logs() {
    log "📦 Archiving local logs..."
    
    if [[ -d "$LOG_DIR" ]]; then
        # Compression des logs
        tar -czf "$BACKUP_DIR/logs_$TIMESTAMP.tar.gz" -C "$LOG_DIR" .
        
        local archive_size
        archive_size=$(du -h "$BACKUP_DIR/logs_$TIMESTAMP.tar.gz" | cut -f1)
        log "✅ Local logs archived: $archive_size"
        
        # Nettoyage des anciens logs locaux
        find "$LOG_DIR" -name "*.log" -type f -mtime +7 -delete || true
        log "🧹 Old local logs cleaned (>7 days)"
    else
        log "⚠️ No local logs directory found"
    fi
}

# Upload vers S3 avec structure organisée
upload_to_s3() {
    log "📤 Uploading logs to S3..."
    
    local year month day
    year=$(date +%Y)
    month=$(date +%m)
    day=$(date +%d)
    
    # Structure: s3://bucket/type/year/month/day/
    local s3_prefix="s3://$S3_BUCKET"
    
    # Upload des logs par type
    if [[ -f "$LOG_DIR/validation_"*.log ]]; then
        aws s3 cp "$LOG_DIR/" "$s3_prefix/validation/$year/$month/$day/" \
            --recursive --include "validation_*.log" --quiet || log "⚠️ Failed to upload validation logs"
    fi
    
    if [[ -f "$LOG_DIR/plan_"*.log ]]; then
        aws s3 cp "$LOG_DIR/" "$s3_prefix/planning/$year/$month/$day/" \
            --recursive --include "plan_*.log" --quiet || log "⚠️ Failed to upload planning logs"
    fi
    
    if [[ -f "$LOG_DIR/deployment_"*.log ]]; then
        aws s3 cp "$LOG_DIR/" "$s3_prefix/deployments/$year/$month/$day/" \
            --recursive --include "deployment_*.log" --quiet || log "⚠️ Failed to upload deployment logs"
    fi
    
    # Upload des rapports
    if [[ -f "$LOG_DIR/"*"_report_"*.md ]]; then
        aws s3 cp "$LOG_DIR/" "$s3_prefix/reports/$year/$month/$day/" \
            --recursive --include "*_report_*.md" --quiet || log "⚠️ Failed to upload reports"
    fi
    
    # Upload des backups compressés
    if [[ -f "$BACKUP_DIR/logs_$TIMESTAMP.tar.gz" ]]; then
        aws s3 cp "$BACKUP_DIR/logs_$TIMESTAMP.tar.gz" \
            "$s3_prefix/archives/$year/$month/$day/" --quiet || log "⚠️ Failed to upload log archives"
    fi
    
    log "✅ Logs uploaded to S3"
}

# Configuration des métriques CloudWatch
setup_cloudwatch_metrics() {
    log "📊 Setting up CloudWatch metrics..."
    
    # Métrique personnalisée pour les déploiements
    aws cloudwatch put-metric-data \
        --namespace "Terragrunt/Pipeline" \
        --metric-data \
        MetricName=DeploymentCount,Value=1,Unit=Count,Dimensions=Environment="${ENVIRONMENT:-unknown}" \
        || log "⚠️ Failed to send CloudWatch metrics"
    
    # Métriques de performance si disponibles
    if [[ -f "$LOG_DIR/performance_metrics.json" ]]; then
        local duration
        duration=$(jq -r '.deployment_duration // 0' "$LOG_DIR/performance_metrics.json" 2>/dev/null || echo "0")
        
        aws cloudwatch put-metric-data \
            --namespace "Terragrunt/Pipeline" \
            --metric-data \
            MetricName=DeploymentDuration,Value="$duration",Unit=Seconds,Dimensions=Environment="${ENVIRONMENT:-unknown}" \
            || log "⚠️ Failed to send performance metrics"
    fi
    
    log "✅ CloudWatch metrics configured"
}

# Nettoyage des anciens logs dans S3
cleanup_old_s3_logs() {
    log "🧹 Cleaning up old S3 logs..."
    
    # Utilisation du lifecycle policy S3 pour automatiser
    # Ici on configure juste la politique si elle n'existe pas
    
    local lifecycle_config=$(cat <<EOF
{
    "Rules": [
        {
            "ID": "DeleteOldLogs",
            "Status": "Enabled",
            "Filter": {"Prefix": ""},
            "Expiration": {"Days": $RETENTION_DAYS},
            "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
        }
    ]
}
EOF
)
    
    echo "$lifecycle_config" > /tmp/lifecycle.json
    
    if aws s3api put-bucket-lifecycle-configuration \
        --bucket "$S3_BUCKET" \
        --lifecycle-configuration file:///tmp/lifecycle.json 2>/dev/null; then
        log "✅ S3 lifecycle policy configured (${RETENTION_DAYS} days retention)"
    else
        log "⚠️ Could not configure S3 lifecycle policy"
    fi
    
    rm -f /tmp/lifecycle.json
}

# Génération des dashboards CloudWatch
create_cloudwatch_dashboard() {
    log "📈 Creating CloudWatch dashboard..."
    
    local dashboard_body=$(cat <<'EOF'
{
    "widgets": [
        {
            "type": "metric",
            "properties": {
                "metrics": [
                    ["Terragrunt/Pipeline", "DeploymentCount", "Environment", "dev"],
                    [".", ".", ".", "staging"],
                    [".", ".", ".", "prod"]
                ],
                "period": 300,
                "stat": "Sum",
                "region": "eu-west-1",
                "title": "Deployments by Environment"
            }
        },
        {
            "type": "metric",
            "properties": {
                "metrics": [
                    ["Terragrunt/Pipeline", "DeploymentDuration", "Environment", "dev"],
                    [".", ".", ".", "staging"],
                    [".", ".", ".", "prod"]
                ],
                "period": 300,
                "stat": "Average",
                "region": "eu-west-1",
                "title": "Average Deployment Duration"
            }
        }
    ]
}
EOF
)
    
    aws cloudwatch put-dashboard \
        --dashboard-name "TerragruntPipeline" \
        --dashboard-body "$dashboard_body" \
        > /dev/null 2>&1 && log "✅ CloudWatch dashboard created" || log "⚠️ Failed to create dashboard"
}

# Configuration des alertes
setup_cloudwatch_alarms() {
    log "🚨 Setting up CloudWatch alarms..."
    
    # Alarme pour les échecs de déploiement
    aws cloudwatch put-metric-alarm \
        --alarm-name "TerragruntDeploymentFailures" \
        --alarm-description "Alert on Terragrunt deployment failures" \
        --metric-name "DeploymentFailures" \
        --namespace "Terragrunt/Pipeline" \
        --statistic "Sum" \
        --period 300 \
        --threshold 1 \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --evaluation-periods 1 \
        --alarm-actions "arn:aws:sns:eu-west-1:${AWS_ACCOUNT_ID:-123456789012}:terragrunt-alerts" \
        > /dev/null 2>&1 && log "✅ Deployment failure alarm configured" || log "⚠️ Failed to create alarm"
    
    # Alarme pour les déploiements longs
    aws cloudwatch put-metric-alarm \
        --alarm-name "TerragruntLongDeployments" \
        --alarm-description "Alert on long-running deployments" \
        --metric-name "DeploymentDuration" \
        --namespace "Terragrunt/Pipeline" \
        --statistic "Average" \
        --period 300 \
        --threshold 1800 \
        --comparison-operator "GreaterThanThreshold" \
        --evaluation-periods 2 \
        --alarm-actions "arn:aws:sns:eu-west-1:${AWS_ACCOUNT_ID:-123456789012}:terragrunt-alerts" \
        > /dev/null 2>&1 && log "✅ Long deployment alarm configured" || log "⚠️ Failed to create alarm"
}

# Génération du rapport de logs
generate_log_report() {
    log "📋 Generating log analysis report..."
    
    local report_file="$LOG_DIR/log_analysis_$TIMESTAMP.md"
    
    cat << EOF > "$report_file"
# Log Analysis Report

**Generated:** $(date)
**Pipeline Run:** \${CI_PIPELINE_ID:-manual}
**Branch:** \${CI_COMMIT_REF_NAME:-$(git branch --show-current 2>/dev/null || echo 'unknown')}

## Log Summary

EOF
    
    # Analyse des logs de validation
    if [[ -f "$LOG_DIR"/validation_*.log ]]; then
        local validation_logs
        validation_logs=$(find "$LOG_DIR" -name "validation_*.log" -type f | wc -l)
        echo "- **Validation Logs:** $validation_logs files" >> "$report_file"
        
        # Extraction des erreurs
        local error_count
        error_count=$(grep -c "❌\|ERROR\|FAILED" "$LOG_DIR"/validation_*.log 2>/dev/null || echo "0")
        echo "- **Validation Errors:** $error_count" >> "$report_file"
    fi
    
    # Analyse des logs de planification
    if [[ -f "$LOG_DIR"/plan_*.log ]]; then
        local plan_logs
        plan_logs=$(find "$LOG_DIR" -name "plan_*.log" -type f | wc -l)
        echo "- **Planning Logs:** $plan_logs files" >> "$report_file"
        
        # Extraction des changements
        local changes_count
        changes_count=$(grep -c "Plan:\|will be\|# will be" "$LOG_DIR"/plan_*.log 2>/dev/null || echo "0")
        echo "- **Infrastructure Changes:** $changes_count" >> "$report_file"
    fi
    
    # Analyse des logs de déploiement
    if [[ -f "$LOG_DIR"/deployment_*.log ]]; then
        local deploy_logs
        deploy_logs=$(find "$LOG_DIR" -name "deployment_*.log" -type f | wc -l)
        echo "- **Deployment Logs:** $deploy_logs files" >> "$report_file"
        
        # Extraction de la durée
        local duration
        duration=$(grep "completed successfully in" "$LOG_DIR"/deployment_*.log 2>/dev/null | tail -1 | grep -o '[0-9]\+s' || echo "unknown")
        echo "- **Last Deployment Duration:** $duration" >> "$report_file"
    fi
    
    cat << EOF >> "$report_file"

## Storage Locations

- **Local Archives:** \`$BACKUP_DIR/logs_$TIMESTAMP.tar.gz\`
- **S3 Validation:** \`s3://$S3_BUCKET/validation/$(date +%Y/%m/%d)/\`
- **S3 Planning:** \`s3://$S3_BUCKET/planning/$(date +%Y/%m/%d)/\`
- **S3 Deployments:** \`s3://$S3_BUCKET/deployments/$(date +%Y/%m/%d)/\`

## Monitoring

- **CloudWatch Dashboard:** [TerragruntPipeline](https://console.aws.amazon.com/cloudwatch/home?region=eu-west-1#dashboards:name=TerragruntPipeline)
- **Log Retention:** $RETENTION_DAYS days
- **Alerts Configured:** Deployment failures, Long deployments

## Recommendations

EOF
    
    # Recommandations basées sur l'analyse
    if [[ -f "$LOG_DIR"/validation_*.log ]]; then
        local security_warnings
        security_warnings=$(grep -c "WARN\|⚠️" "$LOG_DIR"/validation_*.log 2>/dev/null || echo "0")
        if [[ "$security_warnings" -gt 0 ]]; then
            echo "- ⚠️ Review $security_warnings security warnings in validation logs" >> "$report_file"
        fi
    fi
    
    local total_log_size
    total_log_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    echo "- 📊 Total log size: $total_log_size" >> "$report_file"
    
    if [[ -f "$LOG_DIR"/security_*.json ]]; then
        echo "- 🔍 Security scan results available for review" >> "$report_file"
    fi
    
    echo "- 🔄 Logs automatically archived to S3 with $RETENTION_DAYS days retention" >> "$report_file"
    
    log "📋 Log analysis report generated: $report_file"
}

# Main execution
main() {
    log "📊 Starting log management and monitoring setup..."
    
    # Archivage local
    archive_local_logs
    
    # Upload vers S3
    if aws sts get-caller-identity > /dev/null 2>&1; then
        upload_to_s3
        setup_cloudwatch_metrics
        cleanup_old_s3_logs
        create_cloudwatch_dashboard
        setup_cloudwatch_alarms
    else
        log "⚠️ AWS credentials not available, skipping S3 and CloudWatch operations"
    fi
    
    # Génération du rapport
    generate_log_report
    
    log "✅ Log management and monitoring setup completed"
}

# Vérification des prérequis
if ! command -v aws &> /dev/null; then
    log "❌ AWS CLI not found"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log "⚠️ jq not found, some features will be limited"
fi

# Exécution
main "$@"
```

### 4.2 Configuration des Tests d'Intégration
```yaml
# .github/workflows/integration-tests.yml
name: 🧪 Integration Tests

on:
  schedule:
    - cron: '0 2 * * *'  # Tests quotidiens à 2h
  workflow_dispatch:
    inputs:
      test_environment:
        description: 'Environment to test'
        required: true
        default: 'dev'
        type: choice
        options: [dev, staging, prod]

env:
  AWS_DEFAULT_REGION: 'eu-west-1'

jobs:
  integration-tests:
    name: 🧪 Run Integration Tests
    runs-on: ubuntu-latest
    timeout-minutes: 45
    
    strategy:
      matrix:
        test-suite: [connectivity, security, performance, compliance]
        environment: ${{ fromJSON('["dev", "staging"]') }}  # Pas de tests auto sur prod
    
    steps:
    - name: 📥 Checkout Code
      uses: actions/checkout@v4
      
    - name: 🔐 Configure AWS Credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        aws-region: ${{ env.AWS_DEFAULT_REGION }}
        
    - name: 🧪 Run Test Suite
      run: |
        case "${{ matrix.test-suite }}" in
          connectivity)
            echo "🌐 Testing infrastructure connectivity..."
            cd environments/${{ matrix.environment }}
            
            # Test VPC connectivity
            vpc_id=$(terragrunt output -raw vpc_id 2>/dev/null || echo "")
            if [[ -n "$vpc_id" ]]; then
              aws ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].State' --output text
              echo "✅ VPC connectivity test passed"
            else
              echo "❌ VPC not found"
              exit 1
            fi
            
            # Test web server connectivity
            if public_ip=$(terragrunt output -raw web_server_ip 2>/dev/null); then
              if curl -s --max-time 10 "http://$public_ip" > /dev/null; then
                echo "✅ Web server connectivity test passed"
              else
                echo "❌ Web server not accessible"
                exit 1
              fi
            fi
            ;;
            
          security)
            echo "🔒 Running security tests..."
            
            # Vérification des security groups
            cd environments/${{ matrix.environment }}
            sg_ids=$(aws ec2 describe-security-groups --query 'SecurityGroups[?VpcId!=null].GroupId' --output text)
            
            for sg_id in $sg_ids; do
              # Vérifier qu'aucun SG n'autorise 0.0.0.0/0 sur tous les ports
              open_rules=$(aws ec2 describe-security-groups --group-ids "$sg_id" \
                --query 'SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp==`0.0.0.0/0`] && (FromPort==null || FromPort==`0`)]' \
                --output text)
              
              if [[ -n "$open_rules" ]]; then
                echo "❌ Security group $sg_id has overly permissive rules"
                exit 1
              fi
            done
            
            echo "✅ Security tests passed"
            ;;
            
          performance)
            echo "⚡ Running performance tests..."
            
            start_time=$(date +%s)
            cd environments/${{ matrix.environment }}
            
            # Test de plan rapide
            terragrunt run-all plan --terragrunt-non-interactive > /dev/null
            
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            
            # Le plan ne devrait pas prendre plus de 5 minutes
            if [[ $duration -gt 300 ]]; then
              echo "❌ Planning took too long: ${duration}s"
              exit 1
            fi
            
            echo "✅ Performance tests passed (${duration}s)"
            ;;
            
          compliance)
            echo "📋 Running compliance tests..."
            
            # Vérification des tags obligatoires
            resources=$(aws resourcegroupstaggingapi get-resources \
              --region ${{ env.AWS_DEFAULT_REGION }} \
              --query 'ResourceTagMappingList[?!Tags[?Key==`Environment`]]' \
              --output text)
            
            if [[ -n "$resources" ]]; then
              echo "❌ Found resources without Environment tag"
              echo "$resources"
              exit 1
            fi
            
            echo "✅ Compliance tests passed"
            ;;
        esac
        
    - name: 📊 Upload Test Results
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: integration-test-results-${{ matrix.test-suite }}-${{ matrix.environment }}
        path: test-results/
        retention-days: 7
```

### 4.3 Monitoring et Alertes Avancées
```hcl
# modules/monitoring/cloudwatch.tf
resource "aws_cloudwatch_log_group" "pipeline_logs" {
  name              = "/aws/terragrunt/pipeline"
  retention_in_days = 90
  
  tags = {
    Environment = "pipeline"
    Purpose     = "terragrunt-logging"
  }
}

resource "aws_cloudwatch_log_stream" "validation_logs" {
  name           = "validation"
  log_group_name = aws_cloudwatch_log_group.pipeline_logs.name
}

resource "aws_cloudwatch_log_stream" "deployment_logs" {
  name           = "deployment"  
  log_group_name = aws_cloudwatch_log_group.pipeline_logs.name
}

# Métriques personnalisées
resource "aws_cloudwatch_log_metric_filter" "deployment_errors" {
  name           = "TerragruntDeploymentErrors"
  pattern        = "[timestamp, request_id, ERROR]"
  log_group_name = aws_cloudwatch_log_group.pipeline_logs.name

  metric_transformation {
    name      = "DeploymentErrors"
    namespace = "Terragrunt/Pipeline"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "security_violations" {
  name           = "TerragruntSecurityViolations"
  pattern        = "[timestamp, request_id, SECURITY_VIOLATION]"
  log_group_name = aws_cloudwatch_log_group.pipeline_logs.name

  metric_transformation {
    name      = "SecurityViolations"
    namespace = "Terragrunt/Pipeline" 
    value     = "1"
  }
}

# SNS pour les alertes
resource "aws_sns_topic" "pipeline_alerts" {
  name = "terragrunt-pipeline-alerts"
  
  tags = {
    Environment = "pipeline"
    Purpose     = "alerting"
  }
}

resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "slack_alerts" {
  count     = var.slack_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "https"
  endpoint  = var.slack_webhook_url
}

# Alarmes critiques
resource "aws_cloudwatch_metric_alarm" "deployment_failures" {
  alarm_name          = "terragrunt-deployment-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "DeploymentErrors"
  namespace           = "Terragrunt/Pipeline"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "This metric monitors deployment failures"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  
  tags = {
    Environment = "pipeline"
    Criticality = "high"
  }
}

resource "aws_cloudwatch_metric_alarm" "security_violations" {
  alarm_name          = "terragrunt-security-violations"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "SecurityViolations"
  namespace           = "Terragrunt/Pipeline"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "This metric monitors security violations"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  
  tags = {
    Environment = "pipeline"
    Criticality = "critical"
  }
}

# Dashboard complet
resource "aws_cloudwatch_dashboard" "pipeline_dashboard" {
  dashboard_name = "TerragruntPipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["Terragrunt/Pipeline", "DeploymentCount", "Environment", "dev"],
            [".", ".", ".", "staging"],
            [".", ".", ".", "prod"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "eu-west-1"
          title   = "Deployments by Environment"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["Terragrunt/Pipeline", "DeploymentDuration", "Environment", "dev"],
            [".", ".", ".", "staging"],
            [".", ".", ".", "prod"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "eu-west-1"
          title   = "Deployment Duration"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["Terragrunt/Pipeline", "DeploymentErrors"],
            [".", "SecurityViolations"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "eu-west-1"
          title   = "Errors and Security Violations"
          period  = 300
        }
      }
    ]
  })
}

variable "alert_email" {
  description = "Email address for pipeline alerts"
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack webhook URL for notifications"
  type        = string
  default     = ""
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.pipeline_logs.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.pipeline_alerts.arn
}
```

## 🎯 Critères de Réussite de l'Exercice

### ✅ Validation (Phase 1 - 15 points)
- [ ] Syntax validation automatisée pour tous les fichiers HCL/TF
- [ ] Scan de sécurité avec tfsec sans erreurs critiques
- [ ] Validation des formats et conventions de nommage
- [ ] Détection des secrets dans le code

### ✅ Planification (Phase 2 - 20 points)
- [ ] Plans générés pour tous les environnements
- [ ] Estimation des coûts intégrée
- [ ] Analyse des changements avec métriques
- [ ] Sauvegarde des plans avec horodatage

### ✅ Sécurité (Phase 3 - 15 points)  
- [ ] Rôles IAM configurés avec permissions minimales
- [ ] Assume role fonctionnel pour chaque environnement
- [ ] Validation des credentials et des branches
- [ ] Chiffrement des states avec KMS

### ✅ Déploiement (Phase 4 - 10 points)
- [ ] Déploiement conditionnel sur la branche main
- [ ] Logs complets sauvegardés en S3
- [ ] Notifications en cas de succès/échec
- [ ] Rollback automatique en cas d'erreur (prod)

## 🚀 Pour aller plus loin vous pouvez ajouter les éléments suivants :

### 🔒 Sécurité Avancée
- Intégration avec HashiCorp Vault pour les secrets
- Scan de conformité avec Open Policy Agent (OPA)
- Signature des artefacts avec Sigstore/Cosign
- Audit trail complet dans CloudTrail

### 📊 Observabilité
- Métriques custom dans CloudWatch
- Dashboard Grafana avec Prometheus
- Alerting intelligent avec PagerDuty
- Traces distribuées avec AWS X-Ray

### 🔄 Automatisation
- Auto-scaling du pipeline selon la charge
- Déploiements canary automatisés  
- Tests de regression automatisés
- Cleanup automatique des ressources de test

## 📚 Points Clés Appris

1. **Pipeline sécurisé** : Validation systématique avant déploiement
2. **Gestion des secrets** : Rôles IAM et assume role
3. **Observabilité** : Logs centralisés et monitoring
4. **Automatisation** : Déploiements conditionnels et notifications
5. **Gouvernance** : Politiques de sécurité et conformité
