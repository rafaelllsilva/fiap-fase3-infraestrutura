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
  default     = "1.36"
  description = "Versão do Kubernetes do cluster EKS e do managed node group (aws_eks_node_group.this também usa esta variável, para os nós não ficarem para trás num upgrade). Um cluster novo pode nascer em qualquer versão suportada, mas o UPGRADE de um cluster existente sobe um minor por vez — da 1.34 até a 1.36 seriam dois applies, com a 1.35 no meio. Desde julho de 2026 há rollback para o minor anterior dentro de 7 dias, mas trate isso como saída de emergência, não como plano. Liste as versões disponíveis com: aws eks describe-cluster-versions --region <região>."
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
  default     = "t3.medium"
  description = "Tipo de instância EC2 usado pelo managed node group do EKS. t3.medium oferece 2 vCPU e 4 GiB de memória por nó, capacidade adequada para a aplicação, PostgreSQL, addons do EKS e observabilidade com New Relic."
}

variable "node_min_size" {
  type        = number
  default     = 3
  description = "Número mínimo de nós no managed node group (limite inferior do Auto Scaling Group). 2 para espalhar as duas réplicas da app e satisfazer o PodDisruptionBudget."
}

variable "node_max_size" {
  type        = number
  default     = 4
  description = "Número máximo de nós no managed node group (limite superior do Auto Scaling Group)."
}

variable "node_desired_size" {
  type        = number
  default     = 3
  description = "Número desejado de nós no managed node group ao provisionar o cluster."
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

variable "ecr_repository_name" {
  type        = string
  default     = "tech-challenge-app"
  description = "Nome do repositório ECR onde a imagem Docker da aplicação é publicada. Este módulo apenas provisiona o repositório: o build e o push são feitos pela pipeline do repositório da aplicação, que consome o output `ecr_repository_url`."
}

# ---------------------------------------------------------------------------
# Recursos compartilhados no cluster
# ---------------------------------------------------------------------------

variable "namespace" {
  type        = string
  default     = "tech-challenge"
  description = "Namespace Kubernetes compartilhado, criado por este módulo (kubernetes_namespace_v1.this) e consumido pelos repositórios de banco de dados e de aplicação através do output `namespace`. Criado aqui porque nenhum dos dois repositórios pode ser dono dele sem conflitar com o outro."
}

variable "cluster_admin_role_arns" {
  type        = list(string)
  default     = []
  description = "ARNs de IAM roles que recebem acesso admin ao cluster via EKS Access Entries, além do principal que criou o cluster (já coberto por bootstrap_cluster_creator_admin_permissions). O default vazio basta no AWS Academy Learner Lab, onde todos os pipelines usam a mesma role de sessão; fora do lab, use para dar acesso às roles de CI dos repositórios de app e banco."
}
