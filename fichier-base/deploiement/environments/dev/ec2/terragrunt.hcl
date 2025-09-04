include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_parent_terragrunt_dir()}/modules/ec2"
}

dependency "vpc" {
  config_path = "../vpc"
  
  mock_outputs = {
    public_subnet_ids = ["subnet-fake-1", "subnet-fake-2"]
  }
}

dependency "security_group" {
  config_path = "../security-group"
  
  mock_outputs = {
    security_group_id = "sg-fake-id"
  }
}

inputs = {
  environment        = "dev"
  instance_type      = "t3.micro"
  instance_count     = 1
  subnet_ids         = dependency.vpc.outputs.public_subnet_ids
  security_group_ids = [dependency.security_group.outputs.security_group_id]
}