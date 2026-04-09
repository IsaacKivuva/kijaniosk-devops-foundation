terraform {
  backend "s3" {
    bucket         = "kijanikiosk-terraform-state-2111-2550-8279"
    key            = "week4/friday/terraform.tfstate"
    region         = "af-south-1"
    dynamodb_table = "kijanikiosk-terraform-locks"
    encrypt        = true
  }
}