include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/security-group"
}

dependency "vpc" {
  config_path = "../vpc"
  
  mock_outputs = {
    vpc_id = "vpc-fake-id"
  }
  
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment   = "dev"
  vpc_id        = dependency.vpc.outputs.vpc_id
  allowed_ports = [80, 22]
}