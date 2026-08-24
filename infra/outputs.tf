# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Nome do cluster EKS criado."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Endpoint da API do cluster EKS."
}

output "cluster_arn" {
  value       = module.eks.cluster_arn
  description = "ARN do cluster EKS."
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Certificado (CA) do cluster EKS, em base64. Não é segredo (é a chave pública do CA), mas necessário para qualquer provider kubernetes/kubectl se autenticar no cluster — inclusive de um futuro root module desmembrado (via terraform_remote_state, já que o state está em S3)."
}

output "configure_kubectl" {
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  description = "Comando para configurar o kubectl local apontando para o cluster EKS criado."
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID da VPC criada."
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
  description = "URL do repositório ECR usado para publicar a imagem Docker da aplicação (ex.: em `docker push <url>:<tag>`)."
}
