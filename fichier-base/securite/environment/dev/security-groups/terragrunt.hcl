include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Dépendance explicite au VPC
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-fake"
  }
}

terraform {
  # Utiliser le module principal au lieu du sous-module http-80
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git?ref=v4.0.0"
  
  # Hook statique pour vérifier les permissions AWS
  before_hook "check_aws_credentials" {
    commands = ["plan", "apply"]
    execute = ["aws", "sts", "get-caller-identity"]
  }
  
  # Hook pour valider que AWS CLI est configuré
  before_hook "validate_aws_config" {
    commands = ["plan", "apply"]
    execute = ["echo", "🔗 Validating AWS configuration..."]
  }
  
  # Hook après apply pour lister tous les security groups du compte
  after_hook "list_all_security_groups" {
    commands = ["apply"]
    execute = [
      "bash", "-c", 
      "echo '✅ Security group created successfully!' && aws ec2 describe-security-groups --query 'SecurityGroups[?GroupName==`hooks-exercise-web-sg`].{Name:GroupName,ID:GroupId}' --output table"
    ]
  }
}

# Configuration pour le Web Security Group
inputs = {
  name        = "hooks-exercise-web-sg"
  description = "Security group for web servers"
  vpc_id      = dependency.vpc.outputs.vpc_id

  # Règles d'entrée (ingress)
  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH from VPC"
      cidr_blocks = "10.0.0.0/16"
    }
  ]

  # Règles de sortie (egress)
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "All outbound traffic"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Name        = "hooks-exercise-web-sg"
    Environment = "dev"
    Project     = "hooks-exercise"
  }
}