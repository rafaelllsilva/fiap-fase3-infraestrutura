# Provisiona a infraestrutura: VPC, cluster EKS com addons, managed
# node group, repositório ECR e as capacidades de cluster compartilhadas
# (namespace, StorageClass default).
#
# Este módulo NÃO implanta banco de dados nem aplicação. Esses componentes têm
# ciclo de vida próprio (deploy frequente, enquanto a infraestrutura aqui leva
# ~15-20 min e muda raramente) e vivem em repositórios separados, que se
# integram a este lendo os valores de outputs.tf via:
#
#   data "terraform_remote_state" "infra" { backend = "s3" ... }
#
# Ou seja, outputs.tf é o contrato público deste módulo — ver README.md, seção
# "Integração com os outros repositórios".

# ---------------------------------------------------------------------------
# 1. Zonas de disponibilidade e cálculo de subnets
# ---------------------------------------------------------------------------
# Usadas para distribuir as subnets da VPC. Filtra AZs realmente utilizáveis
# sem opt-in adicional (exclui Local Zones/Wavelength).
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Usa as N primeiras AZs disponíveis na região (N = var.az_count).
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # CIDRs de subnet calculados a partir de var.vpc_cidr via cidrsubnet(),
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 100)]
}

# ---------------------------------------------------------------------------
# 2. Rede: VPC com subnets públicas/privadas, Internet Gateway e NAT Gateway
# ---------------------------------------------------------------------------
# Módulo oficial. Cria a VPC, o Internet Gateway (rota das subnets
# públicas), o NAT Gateway (rota de saída das subnets privadas, por onde os
# nós do EKS puxam imagens do ECR e acessam a API do cluster) e as route
# tables associadas a cada tipo de subnet.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Tags de descoberta exigidas pelo EKS / AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# ---------------------------------------------------------------------------
# 3. Cluster EKS + addons + Managed Node Group
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # Role de serviço pré-existente do AWS Academy que é utilizada ao invés de criar novas roles
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.lab_role_name}"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = local.lab_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = module.vpc.private_subnets

    # Endpoint público habilitado para o runner de CI aplicar os manifestos
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# --- Addons do EKS ---------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# Habilita volumes persistentes (PersistentVolumeClaim) no cluster
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# StorageClass padrão do cluster, atendida pelo driver CSI do addon acima.
resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi_driver]
}

# Fornece as métricas de CPU/memória consumidas por HorizontalPodAutoscaler.
# Sem ele qualquer HPA dos outros repositórios fica em <unknown>.
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# Launch template dos nodes
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Nós do EKS com IMDSv2 alcançável por pods (hop limit 2)"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 obrigatório
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# --- Managed node group ----------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = local.lab_role_arn
  subnet_ids      = module.vpc.private_subnets

  # Amarra a versão do kubelet à do control plane
  version = var.kubernetes_version

  instance_types = [var.node_instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  # Os nodes só ficam Ready com CNI e kube-proxy 
  depends_on = [aws_eks_addon.vpc_cni, aws_eks_addon.kube_proxy]

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# ---------------------------------------------------------------------------
# 4. Repositório ECR
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  # O repositório é apenas provisionado aqui; o build e o push da imagem são
  # feitos pela pipeline do repositório da app, que consome o output
  # `ecr_repository_url`. force_delete permite destruir o repo com imagens dentro.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# ---------------------------------------------------------------------------
# 5. Recursos compartilhados no cluster
# ---------------------------------------------------------------------------
# Namespace onde os repositórios de banco de dados e de app deve ser implantados
resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
      environment                    = var.environment
    }
  }

  depends_on = [aws_eks_node_group.this]
}

# --- Access entries adicionais ---------------------------------------------
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
