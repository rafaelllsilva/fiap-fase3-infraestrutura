terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Provisiona um cluster Kubernetes local (Kind), rodando em Docker.
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.9"
    }
    # Aplica os manifestos YAML de /k8s no cluster (o "deploy" via Terraform).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  # Backend local: o cluster é efêmero (criado e destruído junto com o runner
  # de CI), então o state não precisa ser remoto.
}
