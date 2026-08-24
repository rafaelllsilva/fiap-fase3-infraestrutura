# =============================================================================
# Providers AWS, Kubernetes e kubectl
# =============================================================================
#
# - aws: provisiona VPC, EKS, node group e ECR.
# - kubernetes: autentica no cluster EKS. Nenhum resource deste provider é
#   usado hoje (o deploy dos manifestos é feito via provider kubectl — ver
#   comentário abaixo), mas fica configurado e pronto para uso futuro.
# - kubectl: aplica os manifestos YAML de /k8s no cluster EKS.
# =============================================================================

# ---------------------------------------------------------------------------
# Provider AWS
# ---------------------------------------------------------------------------
# Sem credenciais hardcoded: vêm da cadeia padrão do AWS SDK (variáveis de
# ambiente AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, perfil em
# ~/.aws/credentials, OIDC do runner de CI, etc.).
provider "aws" {
  region = var.aws_region

  # default_tags propaga estas tags a todo recurso do provider aws que
  # suportar tags (bloco aninhado — não um atributo direto).
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
# Autentica no cluster EKS usando os outputs do módulo eks (main.tf) e um
# token de curta duração via data.aws_eks_cluster_auth.this (também em
# main.tf).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# ---------------------------------------------------------------------------
# Provider kubectl
# ---------------------------------------------------------------------------
# Aplica os manifestos YAML brutos de /k8s (kubectl_manifest, em main.tf).
# Usa a mesma autenticação do provider kubernetes acima. Mantido em vez do
# resource kubernetes_manifest (provider kubernetes) porque este último faz
# validação de schema contra a API do cluster durante o `plan`, o que quebra
# quando o cluster é criado na mesma `apply` que aplica os manifestos.
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}
