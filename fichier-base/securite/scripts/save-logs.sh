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