# environments/dev/vpc/terragrunt.hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

terraform {
  source = "../../../modules//vpc"
}

inputs = {
  aws_region = local.account_vars.locals.aws_region
  vpc_name   = "vpc-${local.account_vars.locals.account_name}"
  vpc_cidr   = "10.0.0.0/16"
  
  tags = merge(
    local.account_vars.locals.environment_tags,
    {
      Name = "vpc-${local.account_vars.locals.account_name}"
    }
  )
}