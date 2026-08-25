# Provisiona a infraestrutura AWS (VPC + EKS + node group gerenciado + ECR)
# e faz o deploy do banco de dados e da aplicação aplicando os manifestos de
# /k8s — tudo via Terraform, como exige o item 3.3 do enunciado (sem kubectl
# direto na pipeline para deploy). Roda inteiramente dentro do runner do
# GitHub Actions.
#
# Este módulo raiz mistura hoje duas responsabilidades — provisionamento de
# infraestrutura (VPC/EKS/node group/ECR, de ciclo de vida longo) e deploy
# de aplicação (Postgres/app, de ciclo de vida curto). O plano é desmembrar
# essas duas partes futuramente — ver seção "Roadmap" no CLAUDE.md.

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

# Necessário para volumeClaimTemplates do Postgres
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

# Metrics server para o funcionamento do HPA
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
# 4. Repositório ECR e publicação da imagem da aplicação
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  # Faz o delete o repo ECR criado no destroy
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

locals {
  # Tag de destino no ECR,
  app_image_tag = length(split(":", var.app_image)) > 1 ? split(":", var.app_image)[1] : "latest"
  ecr_image     = "${aws_ecr_repository.this.repository_url}:${local.app_image_tag}"
}

# Push da imagem Docker no repositório ECR
resource "null_resource" "push_image" {
  triggers = {
    image = var.app_image
    repo  = aws_ecr_repository.this.repository_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.this.repository_url}
      docker tag ${var.app_image} ${local.ecr_image}
      docker push ${local.ecr_image}
    EOT
  }

  depends_on = [aws_ecr_repository.this]
}

# ---------------------------------------------------------------------------
# 5. Deploy dos manifestos YAML, em ordem de dependência (via depends_on).
# ---------------------------------------------------------------------------
locals {
  manifests_path = "${path.module}/../k8s"

  # Renderiza os manifestos (templatefile onde há variáveis, file() nos demais).
  namespace_raw          = file("${local.manifests_path}/namespace.yaml")
  database_configmap_raw = file("${local.manifests_path}/database/configmap.yaml")
  database_postgres_raw  = file("${local.manifests_path}/database/postgres.yaml")
  database_netpol_raw    = file("${local.manifests_path}/database/network-policy.yaml")
  app_netpol_raw         = file("${local.manifests_path}/app/network-policy.yaml")
  app_pdb_raw            = file("${local.manifests_path}/app/pod-disruption-budget.yaml")

  database_secret_raw = templatefile("${local.manifests_path}/database/secret.yaml", {
    db_password = var.db_password
  })
  app_secret_raw = templatefile("${local.manifests_path}/app/secret.yaml", {
    jwt_secret = var.jwt_secret
  })
  app_deployment_raw = templatefile("${local.manifests_path}/app/app-escalavel.yaml", {
    app_image = local.ecr_image
  })

  # Split de YAML multi-documento. Prefixa "\n" para que um "---" no início do
  # arquivo vire um separador limpo "\n---\n" (senão o primeiro documento sairia
  # com um "---" solto no começo). Blocos vazios são descartados.
  namespace_docs          = [for d in split("\n---\n", "\n${local.namespace_raw}") : trimspace(d) if trimspace(d) != ""]
  database_configmap_docs = [for d in split("\n---\n", "\n${local.database_configmap_raw}") : trimspace(d) if trimspace(d) != ""]
  database_secret_docs    = [for d in split("\n---\n", "\n${local.database_secret_raw}") : trimspace(d) if trimspace(d) != ""]
  database_postgres_docs  = [for d in split("\n---\n", "\n${local.database_postgres_raw}") : trimspace(d) if trimspace(d) != ""]
  database_netpol_docs    = [for d in split("\n---\n", "\n${local.database_netpol_raw}") : trimspace(d) if trimspace(d) != ""]
  app_secret_docs         = [for d in split("\n---\n", "\n${local.app_secret_raw}") : trimspace(d) if trimspace(d) != ""]
  app_deployment_docs     = [for d in split("\n---\n", "\n${local.app_deployment_raw}") : trimspace(d) if trimspace(d) != ""]
  app_netpol_docs         = [for d in split("\n---\n", "\n${local.app_netpol_raw}") : trimspace(d) if trimspace(d) != ""]
  app_pdb_docs            = [for d in split("\n---\n", "\n${local.app_pdb_raw}") : trimspace(d) if trimspace(d) != ""]

  app_deployment_doc_count = length([
    for d in split("\n---\n", "\n${file("${local.manifests_path}/app/app-escalavel.yaml")}") : d
    if trimspace(d) != ""
  ])
}

resource "kubectl_manifest" "namespace" {
  count      = length(local.namespace_docs)
  yaml_body  = local.namespace_docs[count.index]
  depends_on = [aws_eks_node_group.this]
}

resource "kubectl_manifest" "database_configmap" {
  count      = length(local.database_configmap_docs)
  yaml_body  = local.database_configmap_docs[count.index]
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "database_secret" {
  count      = length(local.database_secret_docs)
  yaml_body  = local.database_secret_docs[count.index]
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "app_secret" {
  count      = length(local.app_secret_docs)
  yaml_body  = local.app_secret_docs[count.index]
  depends_on = [kubectl_manifest.namespace]
}

# Deployment do Postgres
resource "kubectl_manifest" "database_postgres" {
  count            = length(local.database_postgres_docs)
  yaml_body        = local.database_postgres_docs[count.index]
  wait_for_rollout = true
  depends_on = [
    kubectl_manifest.database_configmap,
    kubectl_manifest.database_secret,
    aws_eks_addon.ebs_csi_driver,
    kubernetes_storage_class_v1.ebs_gp3,
  ]
}

# Deployment da App
resource "kubectl_manifest" "app_deployment" {
  count            = local.app_deployment_doc_count
  yaml_body        = local.app_deployment_docs[count.index]
  wait_for_rollout = true
  depends_on = [
    kubectl_manifest.database_postgres,
    kubectl_manifest.app_secret,
    null_resource.push_image,
    aws_eks_addon.metrics_server,
  ]
}

resource "kubectl_manifest" "database_network_policy" {
  count      = length(local.database_netpol_docs)
  yaml_body  = local.database_netpol_docs[count.index]
  depends_on = [kubectl_manifest.app_deployment]
}

resource "kubectl_manifest" "app_network_policy" {
  count      = length(local.app_netpol_docs)
  yaml_body  = local.app_netpol_docs[count.index]
  depends_on = [kubectl_manifest.app_deployment]
}

resource "kubectl_manifest" "app_pod_disruption_budget" {
  count      = length(local.app_pdb_docs)
  yaml_body  = local.app_pdb_docs[count.index]
  depends_on = [kubectl_manifest.app_deployment]
}
