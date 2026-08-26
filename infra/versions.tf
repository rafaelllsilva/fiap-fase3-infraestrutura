terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # AWS
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
    # Kubernetes — namespace compartilhado e StorageClass default (main.tf)
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}
