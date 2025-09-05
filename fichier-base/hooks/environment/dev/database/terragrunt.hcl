include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Dépendances multiples
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id = "vpc-fake"
    private_subnets = ["subnet-fake1", "subnet-fake2"]
  }
}

dependency "security_groups" {
  config_path = "../security-groups"
  mock_outputs = {
    database_security_group_id = "sg-fake"
  }
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds.git?ref=v6.0.0"
  before_hook "check_subnets" {
    commands = ["plan", "apply"]
    execute = ["echo", "🗄️ Preparing RDS deployment in subnets: ${join(",", dependency.vpc.outputs.private_subnets)}"]
  }
  
  before_hook "validate_security_group" {
    commands = ["plan", "apply"]
    execute = [
      "aws", "ec2", "describe-security-groups",
      "--group-ids", "${dependency.security_groups.outputs.database_security_group_id}",
      "--query", "SecurityGroups[0].GroupId",
      "--output", "text"
    ]
  }
  
  after_hook "test_connectivity" {
    commands = ["apply"]
    execute = ["echo", "🔌 RDS instance created. Test connectivity from EC2 instances in the same VPC."]
  }
  
  error_hook "cleanup_on_error" {
    commands = ["apply"]
    execute = ["echo", "❌ RDS deployment failed. Check AWS console for detailed error information."]
  }
}

inputs = {
  identifier = "hooks-exercise-db"
  
  engine               = "mysql"
  engine_version       = "8.0"
  family              = "mysql8.0"
  major_engine_version = "8.0"
  instance_class      = "db.t3.micro"
  
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = false  # Pour simplifier l'exercice
  
  db_name  = "exercisedb"
  username = "admin"
  password = "changeme123!"  # En production, utiliser AWS Secrets Manager
  port     = 3306
  
  multi_az               = false
  db_subnet_group_name   = null  # Sera créé automatiquement
  vpc_security_group_ids = [dependency.security_groups.outputs.database_security_group_id]
  subnet_ids            = dependency.vpc.outputs.private_subnets
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  deletion_protection = false  # Pour faciliter la suppression dans l'exercice
  
  tags = {
    Name = "hooks-exercise-database"
  }
}