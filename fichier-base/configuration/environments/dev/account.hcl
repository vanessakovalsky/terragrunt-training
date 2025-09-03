# environments/dev/account.hcl
locals {
  account_name = "dev"
  aws_region   = "us-east-2"
  
  environment_tags = {
    Environment = "development"
  }
}