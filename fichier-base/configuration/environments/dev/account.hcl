# environments/dev/account.hcl
locals {
  account_name = "dev-vanessa"
  aws_region   = "us-east-2"
  
  environment_tags = {
    Environment = "development"
  }
}