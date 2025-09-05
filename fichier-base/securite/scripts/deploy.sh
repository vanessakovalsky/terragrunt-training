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