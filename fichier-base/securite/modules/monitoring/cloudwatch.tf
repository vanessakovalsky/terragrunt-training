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