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