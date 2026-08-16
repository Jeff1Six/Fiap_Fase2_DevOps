terraform {
  backend "s3" {
    bucket       = "togglemaster-desafio3-terraform-state"
    key          = "fase3/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}