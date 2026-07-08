# Remote state for the prod environment. Kept in a separate bucket/table
# from dev so a mistake in one environment's state can never touch the other.
terraform {
  backend "s3" {
    bucket         = "flightreservation-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "flightreservation-tfstate-lock-prod"
    encrypt        = true
  }
}
