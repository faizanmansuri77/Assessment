aws_region  = "ap-south-1"
project     = "flightreservation"
environment = "dev"

vpc_cidr             = "10.0.0.0/16"
azs                  = ["ap-south-1a", "ap-south-1b"]
public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

container_image = "public.ecr.aws/nginx/nginx:latest"

# db_password intentionally omitted here - pass via
# TF_VAR_db_password or a local *.auto.tfvars that is gitignored.
