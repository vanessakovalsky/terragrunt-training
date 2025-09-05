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
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git//modules/http-80?ref=v4.0.0"
  before_hook "check_dependencies" {
    commands = ["plan", "apply"]
    execute = ["echo", "🔗 Checking VPC dependency: ${dependency.vpc.outputs.vpc_id}"]
  }
  
  before_hook "validate_vpc_exists" {
    commands = ["plan", "apply"]
    execute = [
      "aws", "ec2", "describe-vpcs", 
      "--vpc-ids", "${dependency.vpc.outputs.vpc_id}",
      "--query", "Vpcs[0].VpcId",
      "--output", "text"
    ]
  }
  
  after_hook "list_security_groups" {
    commands = ["apply"]
    execute = [
      "aws", "ec2", "describe-security-groups",
      "--filters", "Name=vpc-id,Values=${dependency.vpc.outputs.vpc_id}",
      "--query", "SecurityGroups[].{Name:GroupName,ID:GroupId}",
      "--output", "table"
    ]
  }
}

# Configuration multi-modules pour créer plusieurs security groups
inputs = {
  vpc_id = dependency.vpc.outputs.vpc_id
  
  # Web Security Group
  web_security_group = {
    name        = "hooks-exercise-web-sg"
    description = "Security group for web servers"
    
    ingress_rules = [
      {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        description = "HTTP"
      },
      {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        description = "HTTPS"
      },
      {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["10.0.0.0/16"]
        description = "SSH from VPC"
      }
    ]
    
    egress_rules = [
      {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        description = "All outbound"
      }
    ]
  }
  
  # Database Security Group
  database_security_group = {
    name        = "hooks-exercise-db-sg"
    description = "Security group for RDS database"
    
    ingress_rules = [
      {
        from_port   = 3306
        to_port     = 3306
        protocol    = "tcp"
        cidr_blocks = ["10.0.0.0/16"]
        description = "MySQL from VPC"
      }
    ]
  }
}