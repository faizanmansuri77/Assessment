# Remote state for the dev environment.
# Bucket/table are expected to already exist (create once, outside Terraform,
# or via a small bootstrap stack) since state storage can't depend on itself.
terraform {
  backend "s3" {
    bucket         = "flightreservation-tfstate-dev"
    key            = "dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "flightreservation-tfstate-lock-dev"
    encrypt        = true
  }
}
