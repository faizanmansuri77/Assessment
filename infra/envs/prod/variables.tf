variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "flightreservation"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.10.0/24", "10.1.11.0/24"]
}

variable "container_image" {
  type    = string
  default = "public.ecr.aws/nginx/nginx:latest"
}

variable "db_username" {
  type      = string
  default   = "app_user"
  sensitive = true
}

variable "db_password" {
  description = "Set via TF_VAR_db_password / CI secret / Secrets Manager - never commit real prod secrets."
  type        = string
  sensitive   = true
  default     = "ChangeMe_LocalPlanOnly!"
}
