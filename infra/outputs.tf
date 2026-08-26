# =============================================================================
# Contrato de integração deste módulo
# =============================================================================
# Estes outputs são a API pública do repositório de infraestrutura. Os
# repositórios de banco de dados e de aplicação os consomem via:
#
#   data "terraform_remote_state" "infra" {
#     backend = "s3"
#     config  = { bucket = "archtechs-infra", key = "terraform.tfstate", region = "us-east-1" }
#   }
#
# Trate remoções e renomeações como quebra de contrato: há repositórios
# externos lendo estes nomes. Ver README.md, seção "Integração com os outros
# repositórios".
# =============================================================================

# ---------------------------------------------------------------------------
# AWS geral
# ---------------------------------------------------------------------------

output "aws_region" {
  value       = var.aws_region
  description = "Região AWS onde a infraestrutura foi provisionada. Os módulos consumidores precisam dela para o exec plugin `aws eks get-token` e para o login no ECR."
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "ID da conta AWS onde a infraestrutura foi provisionada."
}

# ---------------------------------------------------------------------------
# EKS — cluster
# ---------------------------------------------------------------------------

output "cluster_name" {
  value       = aws_eks_cluster.this.name
  description = "Nome do cluster EKS criado."
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.this.endpoint
  description = "Endpoint da API do cluster EKS. É o `host` dos providers kubernetes/kubectl/helm dos módulos consumidores."
}

output "cluster_arn" {
  value       = aws_eks_cluster.this.arn
  description = "ARN do cluster EKS."
}

output "cluster_certificate_authority_data" {
  value       = aws_eks_cluster.this.certificate_authority[0].data
  description = "Certificado (CA) do cluster EKS, em base64. Não é segredo (é a chave pública do CA), mas é necessário para qualquer provider kubernetes/kubectl se autenticar no cluster — use com base64decode() no argumento cluster_ca_certificate."
}

output "cluster_version" {
  value       = aws_eks_cluster.this.version
  description = "Versão do Kubernetes do control plane. Útil para os módulos consumidores validarem a compatibilidade das apiVersions dos manifestos que aplicam."
}

output "cluster_security_group_id" {
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description = "ID do security group gerenciado pelo EKS, aplicado ao control plane e aos nós. Ponto de partida para regras de acesso adicionais."
}

output "cluster_oidc_issuer_url" {
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
  description = "URL do issuer OIDC do cluster. Disponível mesmo sem um IAM OIDC provider criado (o lab não permite iam:CreateOpenIDConnectProvider) — exposto para o caso de o projeto migrar para uma conta que permita IRSA."
}

output "configure_kubectl" {
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
  description = "Comando para configurar o kubectl local apontando para o cluster EKS criado."
}

# ---------------------------------------------------------------------------
# EKS — managed node group
# ---------------------------------------------------------------------------

output "node_group_name" {
  value       = aws_eks_node_group.this.node_group_name
  description = "Nome do managed node group, necessário para os comandos `aws eks update-nodegroup-config` de scaling/hibernação."
}

output "node_role_arn" {
  value       = local.lab_role_arn
  description = "ARN da IAM role dos nós. É ela que autoriza o pull das imagens do ECR pelos nós — relevante ao ajustar policies de repositório."
}

# ---------------------------------------------------------------------------
# Recursos compartilhados no cluster
# ---------------------------------------------------------------------------

output "namespace" {
  value       = kubernetes_namespace_v1.this.metadata[0].name
  description = "Namespace criado por este módulo. Os repositórios de banco e de aplicação devem implantar dentro dele em vez de criar o próprio."
}

output "storage_class_name" {
  value       = kubernetes_storage_class_v1.ebs_gp3.metadata[0].name
  description = "Nome da StorageClass default do cluster (EBS gp3). O repositório do banco deve referenciá-la no volumeClaimTemplates em vez de declarar a própria StorageClass."
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID da VPC criada."
}

output "vpc_cidr_block" {
  value       = module.vpc.vpc_cidr_block
  description = "Bloco CIDR da VPC. Use nos ipBlock das NetworkPolicies dos módulos consumidores, em vez de um CIDR hardcoded."
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "IDs das subnets públicas da VPC."
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "IDs das subnets privadas da VPC (onde os nós do EKS são provisionados)."
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

output "ecr_repository_url" {
  value       = aws_ecr_repository.this.repository_url
  description = "URL do repositório ECR. A pipeline do repositório da aplicação publica a imagem aqui (`docker push <url>:<tag>`) e referencia a mesma URL no campo image do Deployment."
}

output "ecr_repository_name" {
  value       = aws_ecr_repository.this.name
  description = "Nome do repositório ECR (para comandos `aws ecr` como describe-images e batch-get-image)."
}

output "ecr_repository_arn" {
  value       = aws_ecr_repository.this.arn
  description = "ARN do repositório ECR, para uso em policies IAM."
}

output "ecr_registry_id" {
  value       = aws_ecr_repository.this.registry_id
  description = "ID do registry ECR (conta AWS dona do repositório), usado em `aws ecr get-login-password --registry-ids`."
}
