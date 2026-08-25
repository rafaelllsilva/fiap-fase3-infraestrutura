# =============================================================================
# Providers AWS, Kubernetes e kubectl
# =============================================================================
#
# - aws: provisiona VPC, EKS, node group e ECR.
# - kubernetes: autentica no cluster EKS (via exec plugin `aws eks get-token`).
#   Nenhum resource deste provider é usado hoje (o deploy dos manifestos é
#   feito via provider kubectl — ver comentário abaixo), mas fica configurado
#   e pronto para uso futuro.
# - kubectl: aplica os manifestos YAML de /k8s no cluster EKS.
# =============================================================================

# ---------------------------------------------------------------------------
# Provider AWS
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
    }
  }
}

# ---------------------------------------------------------------------------
# Provider Kubernetes (HashiCorp)
# ---------------------------------------------------------------------------
# Autentica no cluster EKS usando os atributos de aws_eks_cluster.this
# (main.tf) e uma credencial obtida via exec plugin (`aws eks get-token`).
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", aws_eks_cluster.this.name,
      "--region", var.aws_region,
    ]
  }
}

# ---------------------------------------------------------------------------
# Provider kubectl
# ---------------------------------------------------------------------------
# Aplica os manifestos YAML de /k8s (kubectl_manifest, em main.tf).
# Usa a mesma autenticação do provider kubernetes acima.
provider "kubectl" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", aws_eks_cluster.this.name,
      "--region", var.aws_region,
    ]
  }
}
