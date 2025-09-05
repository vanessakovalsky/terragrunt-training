include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=v5.0.0"
  before_hook "check_cidr" {
    commands = ["plan", "apply"]
    execute = ["echo", "🔍 Validating VPC CIDR: ${local.vpc_cidr}"]
 }
  
  after_hook "export_outputs" {
    commands = ["apply"]
    execute = ["echo", "📤 VPC created successfully, outputs will be available for dependent modules"]
  }
}

locals {
  vpc_cidr = "10.0.0.0/16"
}

inputs = {
  name = "hooks-exercise-vpc"
  cidr = local.vpc_cidr
  
  azs             = ["us-east-2a", "us-east-2b", "us-east-2c"]
  public_subnets  = ["10.0.1.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.4.0/24"]
  
  enable_nat_gateway = true
  enable_vpn_gateway = false
  enable_dns_hostnames = true
  enable_dns_support = true
  
  tags = {
    Name = "hooks-exercise-vpc"
  }
}