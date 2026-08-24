terraform {
  # >= 1.10.0 é exigido pelo locking nativo do backend S3 (use_lockfile, ver
  # backend.tf).
  required_version = ">= 1.10.0"

  required_providers {
    # Provisiona a infraestrutura AWS (VPC, EKS, ECR).
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.61"
    }
    # Autentica no cluster EKS. Configurado e pronto para uso; hoje o deploy
    # dos manifestos ainda é feito via provider kubectl (ver comentário em
    # providers.tf), mas o provider kubernetes fica disponível para recursos
    # Kubernetes nativos que venham a ser usados no futuro.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    # Aplica os manifestos YAML de /k8s no cluster EKS (o "deploy" via
    # Terraform).
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
