terraform {
  backend "s3" {
    bucket       = "togglemaster-desafio4-terraform-state"
    key          = "togglemaster/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
