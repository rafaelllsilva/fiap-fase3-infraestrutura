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
# Autentica no cluster EKS usando os atributos de aws_eks_cluster.this
# (main.tf) e uma credencial obtida via exec plugin (`aws eks get-token`).
#
# Por que exec e não `token = data.aws_eks_cluster_auth.this.token`: aquele
# data source produz um token com validade fixa de 15 minutos, lido UMA única
# vez no início do apply e reusado até o fim, sem renovação. Como o apply
# completo (EKS + node group + os dois wait_for_rollout) passa dos 15 min, as
# últimas chamadas à API do cluster morriam com `Unauthorized` — foi
# exatamente o que derrubou kubectl_manifest.app_deployment. Com o exec
# plugin, o client-go invoca o comando sob demanda e o re-executa quando o
# token em cache expira (o `aws eks get-token` devolve um ExecCredential com
# status.expirationTimestamp), então a duração do apply deixa de importar.
#
# `aws eks get-token` apenas assina uma URL do STS — não faz leitura de IAM,
# então continua compatível com os denies do AWS Academy Learner Lab (ver
# CLAUDE.md). O binário `aws` já é pré-requisito do runner: null_resource
# .push_image (main.tf) chama `aws ecr get-login-password` via local-exec.
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
# Aplica os manifestos YAML brutos de /k8s (kubectl_manifest, em main.tf).
# Usa a mesma autenticação do provider kubernetes acima (ver o comentário lá
# sobre o exec plugin). Mantido em vez do resource kubernetes_manifest
# (provider kubernetes) porque este último faz validação de schema contra a
# API do cluster durante o `plan`, o que quebra quando o cluster é criado na
# mesma `apply` que aplica os manifestos.
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
