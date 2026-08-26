# =============================================================================
# Providers AWS e Kubernetes
# =============================================================================
#
# - aws: provisiona VPC, EKS, node group e ECR.
# - kubernetes: cria os recursos de cluster compartilhados deste módulo —
#   kubernetes_namespace_v1.this e kubernetes_storage_class_v1.ebs_gp3 (main.tf).
#   Autentica via exec plugin (`aws eks get-token`).
#
# Não há provider kubectl aqui: o deploy de banco e aplicação saiu deste
# repositório e é feito pelos repositórios próprios de cada componente.
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
# Os repositórios de app e banco configuram este mesmo provider a partir dos
# outputs deste módulo, lidos via terraform_remote_state — ver README.md.
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
