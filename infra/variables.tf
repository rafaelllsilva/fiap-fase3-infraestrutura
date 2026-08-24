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
  default     = "1.34"
  description = "Versão do Kubernetes do cluster EKS e do managed node group (aws_eks_node_group.this também usa esta variável, para os nós não ficarem para trás num upgrade). Consulte as versões atualmente suportadas pela AWS antes de alterar o default — o EKS sobe um minor por vez e o upgrade é irreversível. Liste as opções com: aws eks describe-cluster-versions --region <região>."
}

variable "lab_role_name" {
  type        = string
  default     = "LabRole"
  description = "Nome da IAM role de serviço pré-existente no ambiente de laboratório (AWS Academy Learner Lab), reaproveitada como IAM role do cluster EKS e do node group — o ambiente não permite iam:CreateRole. Ela precisa confiar em eks.amazonaws.com e ec2.amazonaws.com e ter as policies AmazonEKSClusterPolicy, AmazonEKSWorkerNodePolicy e AmazonEC2ContainerRegistryReadOnly (a LabRole padrão do lab já atende). Ajuste via TF_VAR_lab_role_name se o nome real na sua conta for diferente. Ver seção \"Ambiente de laboratório (AWS Academy Learner Lab)\" no CLAUDE.md."
}

# ---------------------------------------------------------------------------
# EKS — managed node group
# ---------------------------------------------------------------------------

variable "node_instance_type" {
  type        = string
  default     = "t3.small"
  description = "Tipo de instância EC2 usado pelo managed node group do EKS. t3.small (2 vCPU / 2 GB, teto de 11 pods por nó) é o mínimo viável para o workload atual: a app pede 2 réplicas de 250m CPU e 512Mi cada, mais o Postgres e os addons. Em t3.micro (1 GB, teto de 4 pods, já consumidos pelo coredns) os pods ficam Pending."
}

variable "node_min_size" {
  type        = number
  default     = 2
  description = "Número mínimo de nós no managed node group (limite inferior do Auto Scaling Group). 2 para espalhar as duas réplicas da app e satisfazer o PodDisruptionBudget."
}

variable "node_max_size" {
  type        = number
  default     = 4
  description = "Número máximo de nós no managed node group (limite superior do Auto Scaling Group)."
}

variable "node_desired_size" {
  type        = number
  default     = 2
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
