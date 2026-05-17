# --- CONFIGURACIÓN DE TERRAFORM ---
terraform {
  required_version = ">= 1.5.0"
  backend "s3" {
    bucket         = "vault-umb-terraform-state"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-east-2"
    encrypt        = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
