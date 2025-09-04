# Configuration partagée par tous les environnements
locals {
  # Lire les variables d'environnement depuis un fichier YAML
  env_vars = yamldecode(file("${get_terragrunt_dir()}/env.yaml"))
  
  # Configuration commune
  common_tags = {
    Project     = "terragrunt-workshop"
    ManagedBy   = "terragrunt"
    Environment = local.env_vars.environment
  }
}

# Variables communes
inputs = merge(
  local.env_vars,
  {
    project_name = "terragrunt-workshop"
    common_tags  = local.common_tags
  }
)