terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    helm = {
      source = "hashicorp/helm"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "academy"
}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}
