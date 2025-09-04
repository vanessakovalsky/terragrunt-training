include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/vpc"
}

inputs = {
  environment             = "dev"
  vpc_cidr               = "10.10.0.0/16"
  availability_zones     = ["eu-west-1a", "eu-west-1b"]
  public_subnet_cidrs    = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs   = ["10.10.11.0/24", "10.10.12.0/24"]
}