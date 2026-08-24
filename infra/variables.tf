# ---------------------------------------------------------------------------
# AWS geral
# ---------------------------------------------------------------------------

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Região AWS onde a infraestrutura (VPC, EKS, ECR) será provisionada."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Nome do ambiente (ex.: dev, staging, prod), usado nas tags padrão de todos os recursos."
}

variable "project_name" {
  type        = string
  default     = "archtechs-infra"
  description = "Nome do projeto, usado como prefixo de nomes (ex.: VPC) e nas tags padrão de todos os recursos."
}

# ---------------------------------------------------------------------------
# Rede (VPC)
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "Bloco CIDR da VPC. As subnets públicas e privadas são calculadas a partir deste CIDR."
}

variable "az_count" {
  type        = number
  default     = 2
  description = "Número de zonas de disponibilidade a usar (mínimo 2, exigido pelo EKS). Cada AZ recebe uma subnet pública e uma privada."
}

# ---------------------------------------------------------------------------
# EKS — cluster
# ---------------------------------------------------------------------------

variable "cluster_name" {
  type        = string
  default     = "tech-challenge"
  description = "Nome do cluster EKS. Também usado nas tags de descoberta kubernetes.io/cluster/<nome> das subnets da VPC."
}

variable "kubernetes_version" {
  type        = string
  default     = "1.33"
  description = "Versão do Kubernetes do cluster EKS. Consulte as versões atualmente suportadas pela AWS antes de alterar o default."
}

variable "lab_role_name" {
  type        = string
  default     = "LabRole"
  description = "Nome da IAM role de serviço pré-existente no ambiente de laboratório (AWS Academy Learner Lab), reaproveitada como IAM role do cluster EKS e dos node groups — o ambiente não permite iam:CreateRole nem iam:GetRole. Ajuste via TF_VAR_lab_role_name se o nome real na sua conta for diferente. Ver seção \"Ambiente de laboratório (AWS Academy Learner Lab)\" no CLAUDE.md."
}

# ---------------------------------------------------------------------------
# EKS — managed node group
# ---------------------------------------------------------------------------

variable "node_instance_type" {
  type        = string
  default     = "t3.micro"
  description = "Tipo de instância EC2 usado pelo managed node group do EKS."
}

variable "node_min_size" {
  type        = number
  default     = 1
  description = "Número mínimo de nós no managed node group (limite inferior do Auto Scaling Group)."
}

variable "node_max_size" {
  type        = number
  default     = 3
  description = "Número máximo de nós no managed node group (limite superior do Auto Scaling Group)."
}

variable "node_desired_size" {
  type        = number
  default     = 1
  description = "Número desejado de nós no managed node group ao provisionar o cluster."
}

# ---------------------------------------------------------------------------
# ECR e imagem da aplicação
# ---------------------------------------------------------------------------

variable "ecr_repository_name" {
  type        = string
  default     = "tech-challenge-app"
  description = "Nome do repositório ECR onde a imagem Docker da aplicação é publicada pelo Terraform (null_resource.push_image, em main.tf)."
}

variable "app_image" {
  type        = string
  default     = "tech-challenge-app:local"
  description = "Imagem Docker da aplicação buildada no runner (nome:tag local). Na CI é sobrescrita via TF_VAR_app_image com a tag do commit. O Terraform envia essa imagem para o repositório ECR antes do deploy."
}

variable "db_password" {
  type        = string
  sensitive   = true
  default     = "local-dev-postgres-password"
  description = "Senha do Postgres, injetada no Secret db-credentials. Valor de teste; sobrescreva via TF_VAR_db_password em ambientes reais."
}

variable "jwt_secret" {
  type        = string
  sensitive   = true
  default     = "local-dev-jwt-secret-min-32-characters-0001"
  description = "Chave HMAC de assinatura dos tokens JWT (mínimo 32 caracteres), injetada no Secret app-secrets. Valor de teste; sobrescreva via TF_VAR_jwt_secret em ambientes reais."
}
