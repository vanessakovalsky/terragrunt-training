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