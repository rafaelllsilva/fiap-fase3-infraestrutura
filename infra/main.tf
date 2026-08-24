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
  # em vez de literais fixos — funciona para qualquer CIDR configurado.
  # Índices 0..N-1 = subnets públicas; 100..100+N-1 = privadas (offset alto
  # evita colisão se var.az_count crescer no futuro).
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
#
# single_nat_gateway = true -> um único NAT Gateway compartilhado por todas
# as subnets privadas, em vez de um por AZ (one_nat_gateway_per_az = true
# custaria ~N x mais em taxa horária + processamento de dados, sem HA real
# necessária para um cluster de estudo).
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

  # Tags de descoberta exigidas pelo EKS / AWS Load Balancer Controller:
  # - kubernetes.io/cluster/<nome> = shared -> marca as subnets como
  #   pertencentes a este cluster.
  # - kubernetes.io/role/elb = 1 -> subnets públicas elegíveis para Load
  #   Balancers internet-facing.
  # - kubernetes.io/role/internal-elb = 1 -> subnets privadas elegíveis
  #   para Load Balancers internos.
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
# 3. Cluster EKS + Managed Node Group
# ---------------------------------------------------------------------------
# Módulo oficial via registry. ATENÇÃO: no ambiente de laboratório (AWS
# Academy Learner Lab), o módulo (v20+, incluindo esta v21.25) chama
# iam:GetRole de forma incondicional via data.aws_iam_session_context (sem
# nenhuma flag para desativar — confirmado lendo o código-fonte do módulo em
# várias versões), o que é negado pela policy do lab e quebra `plan`/`apply`
# nesse ambiente. Uma cópia local patcheada (removendo só esse data source)
# chegou a ser usada para contornar isso, mas foi revertida a pedido do
# usuário — esse problema específico segue em aberto, sem solução aplicada
# aqui. Os ajustes abaixo (reaproveitar var.lab_role_name, IRSA/KMS
# desabilitados, acesso via access_entries) continuam válidos e cobrem os
# outros bloqueios do lab (iam:CreateRole/iam:CreateOpenIDConnectProvider),
# mas não resolvem o iam:GetRole. Ver "Ambiente de laboratório (AWS Academy
# Learner Lab)" no CLAUDE.md.
data "aws_caller_identity" "current" {}

locals {
  # Deriva o ARN da role da sessão atual (ex.: voclabs) só por parsing de
  # string, sem nenhuma chamada IAM — evita repetir o erro de iam:GetRole.
  # Assume path "/" (padrão em roles de laboratório AWS Academy).
  caller_role_name = split("/", data.aws_caller_identity.current.arn)[1]
  caller_role_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.caller_role_name}"

  # Role de serviço pré-existente do lab (ex.: LabRole), reaproveitada como
  # IAM role do cluster e dos node groups — o ambiente não permite
  # iam:CreateRole.
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.lab_role_name}"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Endpoint público habilitado para o runner de CI aplicar os manifestos
  # (kubectl_manifest, abaixo) e o desenvolvedor local acessarem o cluster
  # sem VPN/bastion (cenário de estudo). Em produção, restrinja via
  # endpoint_public_access_cidrs ou desabilite.
  endpoint_public_access  = true
  endpoint_private_access = true

  # Reaproveita a role de serviço pré-existente do lab em vez de deixar o
  # módulo criar uma nova (iam:CreateRole é negado no ambiente).
  create_iam_role = false
  iam_role_arn    = local.lab_role_arn

  # IRSA (OIDC provider) não é usado hoje no projeto e exigiria
  # iam:CreateOpenIDConnectProvider, também negado no ambiente.
  enable_irsa = false

  # Sem KMS key própria para os secrets do etcd (kms:CreateKey também seria
  # um risco de permissão negada no lab, e não é essencial para o projeto de
  # estudo).
  create_kms_key = false

  # enable_cluster_creator_admin_permissions (mecanismo automático da v20+)
  # também dependeria do data source removido — em vez disso, concede admin
  # explicitamente via Access Entry para a role da sessão atual (estável
  # entre logins do lab, diferente da sessão STS efêmera).
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    lab_session = {
      principal_arn = local.caller_role_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"

      # Mesma restrição do cluster acima: reaproveita a role do lab em vez
      # de criar uma role nova para o node group.
      create_iam_role = false
      iam_role_arn    = local.lab_role_arn

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# Token de autenticação usado pelos providers kubernetes e kubectl
# (providers.tf) para falar com a API do cluster recém-criado.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

# ---------------------------------------------------------------------------
# 4. Repositório ECR e publicação da imagem da aplicação
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

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
  # Tag de destino no ECR, extraída de var.app_image (ex.:
  # "tech-challenge-app:abc1234" -> "abc1234"). Sem ":" no valor, usa
  # "latest" como fallback.
  app_image_tag = length(split(":", var.app_image)) > 1 ? split(":", var.app_image)[1] : "latest"
  ecr_image     = "${aws_ecr_repository.this.repository_url}:${local.app_image_tag}"
}

# Substitui o antigo `kind load docker-image`: a imagem buildada no runner
# (var.app_image) é enviada ao ECR (recurso 4, acima) para que os nós do
# EKS consigam puxá-la — diferente do Kind, o EKS não tem um mecanismo de
# "carregar imagem local direto no nó".
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
#    Cada arquivo pode ter múltiplos documentos; split por "---".
#
#    /k8s é organizado por escopo (namespace.yaml compartilhado, database/ e
#    app/) e os resources kubectl_manifest.* abaixo seguem o mesmo prefixo
#    (database_*/app_*) de propósito: no dia do desmembramento futuro (ver
#    "Roadmap" no CLAUDE.md), dá pra filtrar e mover cada grupo com
#    `terraform state mv` sem precisar redescobrir o que pertence a cada
#    lado.
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
}

resource "kubectl_manifest" "namespace" {
  count      = length(local.namespace_docs)
  yaml_body  = local.namespace_docs[count.index]
  depends_on = [module.eks]
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

# Banco de dados: aplicado depois do config/secret. wait_for_rollout = true faz
# o Terraform esperar o StatefulSet ficar Ready (readinessProbe = pg_isready)
# antes de seguir — assim a app abaixo só sobe com o banco aceitando conexões.
resource "kubectl_manifest" "database_postgres" {
  count            = length(local.database_postgres_docs)
  yaml_body        = local.database_postgres_docs[count.index]
  wait_for_rollout = true
  depends_on       = [kubectl_manifest.database_configmap, kubectl_manifest.database_secret]
}

# Aplicação: só depois do banco pronto e da imagem publicada no ECR.
# wait_for_rollout = true faz o apply esperar o Deployment ficar disponível
# (readinessProbe = /actuator/health/readiness), ou seja, app de pé e conectada.
resource "kubectl_manifest" "app_deployment" {
  count            = length(local.app_deployment_docs)
  yaml_body        = local.app_deployment_docs[count.index]
  wait_for_rollout = true
  depends_on       = [kubectl_manifest.database_postgres, kubectl_manifest.app_secret, null_resource.push_image]
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
