include {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/vpc"
}

inputs = {
  region   = "us-east-2"
  vpc_cidr = "10.0.0.0/16"
  env      = "dev"
}
