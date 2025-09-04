include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_parent_terragrunt_dir()}/modules/vpc"
}

inputs = {
  environment             = "dev"
  vpc_cidr               = "10.10.0.0/16"
  availability_zones     = ["us-east-2a", "us-east-2b", "us-east-2c"]
  public_subnet_cidrs    = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs   = ["10.10.11.0/24", "10.10.12.0/24"]
}