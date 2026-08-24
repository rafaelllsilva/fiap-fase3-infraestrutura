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
# 3. Cluster EKS + addons + Managed Node Group
# ---------------------------------------------------------------------------
# Recursos nativos do provider aws, e não o módulo
# terraform-aws-modules/eks/aws: a partir da v20 esse módulo declara
# `data "aws_iam_session_context" "current"` de forma incondicional (sem
# nenhuma flag para desativar), o que dispara um iam:GetRole sobre a role da
# sessão — negado explicitamente pela policy do AWS Academy Learner Lab e,
# portanto, quebrando `plan`/`apply` neste ambiente. Nenhum dos recursos
# abaixo faz leitura de IAM. Ver "Ambiente de laboratório (AWS Academy
# Learner Lab)" no CLAUDE.md.
data "aws_caller_identity" "current" {}

locals {
  # Role de serviço pré-existente do lab (ex.: LabRole), reaproveitada como
  # IAM role do cluster e do node group — o ambiente não permite
  # iam:CreateRole. Ela confia tanto em eks.amazonaws.com quanto em
  # ec2.amazonaws.com, então serve às duas pontas. O ARN é montado só por
  # concatenação de string, sem nenhuma chamada IAM.
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.lab_role_name}"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = local.lab_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = module.vpc.private_subnets

    # Endpoint público habilitado para o runner de CI aplicar os manifestos
    # (kubectl_manifest, abaixo) e o desenvolvedor local acessarem o cluster
    # sem VPN/bastion (cenário de estudo). Em produção, restrinja via
    # public_access_cidrs ou desabilite.
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # authentication_mode = "API" -> Access Entries (mecanismo atual do EKS),
  # sem o ConfigMap aws-auth. bootstrap_cluster_creator_admin_permissions
  # deixa a própria AWS resolver o principal criador server-side e lhe dar
  # admin no cluster: diferente do módulo, não há chamada iam:GetRole nem
  # parsing de ARN do nosso lado. A AWS normaliza a sessão STS para o ARN da
  # role (ex.: .../role/voclabs), que é estável entre logins do lab.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Deliberadamente fora: encryption_config (kms:CreateKey é risco de
  # permissão negada no lab e não é essencial num cluster de estudo),
  # enabled_cluster_log_types (CloudWatch, custo/permissão extra), provider
  # OIDC/IRSA (exigiria iam:CreateOpenIDConnectProvider, negado) e
  # security_group_ids próprios — o EKS cria e gerencia sozinho o cluster
  # security group que liga control plane e managed node group.
  #
  # bootstrap_self_managed_addons fica no default (true): o cluster nasce com
  # CNI funcionando e os aws_eks_addon abaixo adotam a instalação via
  # resolve_conflicts_on_create = "OVERWRITE". Alterar esse atributo depois
  # força recriação do cluster.

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }
}

# --- Addons do EKS ---------------------------------------------------------
# Sem addon_version: a AWS escolhe a versão default da versão do cluster.
# Sem service_account_role_arn: IRSA está desabilitado, então os addons usam
# a IAM role do nó (local.lab_role_arn).

# CNI e kube-proxy são DaemonSets: ficam ACTIVE mesmo antes de existir nó, por
# isso são criados antes do node group (que depende deles).
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

# Os três addons abaixo rodam como Deployment: sem nó schedulável o addon
# fica DEGRADED e o Terraform falha na criação — daí o depends_on no node
# group.
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

# Necessário para o Postgres: o volumeClaimTemplates de
# k8s/database/postgres.yaml pede 1Gi da StorageClass padrão. Sem um
# provisionador de EBS o PVC fica Pending e o wait_for_rollout do StatefulSet
# trava. Atenção: o addon instala apenas o *driver* — quem cria a StorageClass
# padrão é o kubernetes_storage_class_v1.ebs_gp3 logo abaixo.
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
#
# Por que precisa existir: o volumeClaimTemplates do Postgres omite
# storageClassName de propósito (herança do Kind, onde o local-path provisioner
# é o padrão), então depende de haver uma StorageClass default no cluster. A
# EKS só traz de fábrica a "gp2", que NÃO é anotada como default e ainda usa o
# provisionador in-tree kubernetes.io/aws-ebs — removido do Kubernetes e inerte
# na 1.33. Sem este recurso o PVC fica Pending com "no persistent volumes
# available for this claim and no storage class is set", o postgres-0 nunca é
# escalonado, o postgres-service fica sem endpoints e a app morre em
# CrashLoopBackOff no Flyway (Connection refused).
#
# volume_binding_mode = WaitForFirstConsumer porque um volume EBS é preso a uma
# AZ: com "Immediate" o volume pode nascer numa AZ onde o pod não cabe.
# encrypted usa a chave gerenciada aws/ebs, que não exige kms:CreateKey — o
# mesmo caminho já usado pelo aws_launch_template.node e que funciona no lab.
#
# Primeiro (e hoje único) uso do provider kubernetes: um objeto nativo e
# tipado, em vez de YAML cru via kubectl_manifest.
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

# Necessário para o HPA de k8s/app/app-escalavel.yaml, que escala por CPU e
# memória (item 3.2 do enunciado) — sem métricas ele fica inativo (<unknown>).
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

# --- Launch template dos nós -----------------------------------------------
# Existe por um motivo só: elevar o hop limit do IMDSv2 de 1 para 2.
#
# As AMIs EKS AL2023 usam hop limit 1 de propósito, para impedir que pods
# assumam a IAM role do nó — o caminho suportado pela AWS é dar credenciais
# próprias ao pod via IRSA ou EKS Pod Identity. Neste lab os dois estão
# bloqueados (ver "Ambiente de laboratório" no CLAUDE.md), então os pods que
# precisam da AWS API dependem mesmo da role do nó via IMDS.
#
# Com hop limit 1 o pacote de um pod até 169.254.169.254 morre no salto
# veth -> host, e o ebs-csi-controller (que não usa hostNetwork) entra em
# CrashLoopBackOff com "no EC2 IMDS role found ... context deadline exceeded".
# Com 2, ele alcança o IMDS e assume a LabRole normalmente.
#
# Sem image_id/instance_type aqui de propósito: o EKS continua injetando a AMI
# (via ami_type) e o user-data de bootstrap do node group.
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Nós do EKS com IMDSv2 alcançável por pods (hop limit 2)"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 obrigatório
    http_put_response_hop_limit = 2
  }

  # disk_size não pode ser usado no node group junto com launch_template —
  # o tamanho do disco raiz passa a ser definido aqui.
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

  # Os nós só ficam Ready com a CNI instalada; kube-proxy pela mesma razão.
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

  # app_deployment_docs é o único cujo conteúdo depende de um recurso
  # (local.ecr_image -> aws_ecr_repository.this.repository_url, só conhecido
  # após o apply). O `count` de um resource precisa ser conhecido já no plan,
  # então a contagem de documentos é derivada do arquivo CRU: o templatefile
  # apenas substitui valores inline, nunca muda o número de documentos YAML.
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

# Banco de dados: aplicado depois do config/secret. wait_for_rollout = true faz
# o Terraform esperar o StatefulSet ficar Ready (readinessProbe = pg_isready)
# antes de seguir — assim a app abaixo só sobe com o banco aceitando conexões.
# Depende também do EBS CSI driver: sem ele o PVC do volumeClaimTemplates
# nunca sai de Pending e o wait_for_rollout trava.
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

# Aplicação: só depois do banco pronto e da imagem publicada no ECR.
# wait_for_rollout = true faz o apply esperar o Deployment ficar disponível
# (readinessProbe = /actuator/health/readiness), ou seja, app de pé e conectada.
# O metrics-server entra no depends_on porque o HPA vai no mesmo arquivo do
# Deployment e depende dele para ter métricas.
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
