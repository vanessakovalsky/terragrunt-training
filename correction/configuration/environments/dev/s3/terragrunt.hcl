# environments/dev/s3/terragrunt.hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  env = "development"
}

terraform {
  source = "../../../modules//s3"
}

inputs = {
  bucket_name   = "bucket-${local.account_vars.locals.account_name}"
  env   = local.env
}