variable "region" {
  type        = string
  description = "AWS region"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
}

variable "env" {
  type        = string
  description = "Environment name (prod/dev/staging)"
}
