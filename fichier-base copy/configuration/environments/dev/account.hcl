# environments/dev/account.hcl
locals {
  account_name = "dev"
  aws_region   = "eu-west-1"
  
  environment_tags = {
    Environment = "development"
  }
}