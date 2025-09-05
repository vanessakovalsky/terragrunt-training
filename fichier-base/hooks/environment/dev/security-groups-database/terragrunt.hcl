# security-groups/database/terragrunt.hcl
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
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git?ref=v4.0.0"
}

# Configuration pour le Database Security Group
inputs = {
  name        = "hooks-exercise-db-sg"
  description = "Security group for RDS database"
  vpc_id      = dependency.vpc.outputs.vpc_id

  # Règles d'entrée pour la base de données
  ingress_with_cidr_blocks = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "MySQL from VPC"
      cidr_blocks = "10.0.0.0/16"
    }
  ]

  # Pas de règles de sortie spécifiques (par défaut toutes fermées)
  egress_rules = []

  tags = {
    Name        = "hooks-exercise-db-sg"
    Environment = "dev"
    Project     = "hooks-exercise"
    Type        = "database"
  }
}