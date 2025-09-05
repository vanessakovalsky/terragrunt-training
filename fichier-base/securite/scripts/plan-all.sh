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