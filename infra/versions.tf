terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # AWS
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
    # Kubernetes
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    # Kubectl
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
