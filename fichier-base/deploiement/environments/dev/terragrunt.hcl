# Inclure la configuration racine
include "root" {
  path = find_in_parent_folders("")
}

# Inclure la configuration commune des environnements
include "env" {
  path = "${get_terragrunt_dir()}/../terragrunt.hcl"
}

# Configuration locale
locals {
  env_vars = yamldecode(file("env.yaml"))
}

# Dépendances entre modules
dependencies {
  paths = []
}

# Configuration Terraform
terraform {
  source = "../..//."
}

# Module VPC
dependency "vpc" {
  config_path = "./vpc"
}

# Module Security Group
dependency "security_group" {
  config_path = "./security-group"
}

# Inputs spécifiques
inputs = merge(
  local.env_vars,
  {
    # Variables spécifiques à dev si nécessaire
  }
)