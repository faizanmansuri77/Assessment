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
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
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
  description = "Set via TF_VAR_db_password or a .auto.tfvars that is gitignored - never commit real secrets."
  type        = string
  sensitive   = true
  default     = "ChangeMe_LocalPlanOnly!"
}
