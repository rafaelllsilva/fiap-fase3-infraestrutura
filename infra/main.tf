# Provisiona um cluster Kubernetes local (Kind) e faz o deploy do banco de
# dados e da aplicação aplicando os manifestos de /k8s — tudo via Terraform,
# como exige o item 3.3 do enunciado (sem kubectl direto na pipeline para
# deploy). Roda inteiramente dentro do runner do GitHub Actions.

provider "kind" {}

# ---------------------------------------------------------------------------
# 1. Cluster Kubernetes (Kind)
# ---------------------------------------------------------------------------
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
}

# O provider kubectl é configurado a partir das credenciais do cluster recém
# criado — por isso os manifestos só são aplicados depois que o cluster existe.
provider "kubectl" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  load_config_file       = false
}

# ---------------------------------------------------------------------------
# 2. Carrega a imagem buildada no runner para dentro dos nós do Kind.
#    (kind load não é deploy — é distribuição de imagem, e roda via Terraform.)
# ---------------------------------------------------------------------------
resource "null_resource" "load_image" {
  triggers = {
    image   = var.app_image
    cluster = kind_cluster.this.name
  }

  provisioner "local-exec" {
    command = "kind load docker-image ${var.app_image} --name ${kind_cluster.this.name}"
  }

  depends_on = [kind_cluster.this]
}

# ---------------------------------------------------------------------------
# 3. Deploy dos manifestos YAML, em ordem de dependência (via depends_on).
#    Cada arquivo pode ter múltiplos documentos; split por "---".
# ---------------------------------------------------------------------------
locals {
  manifests_path = "${path.module}/../k8s"

  # Renderiza os manifestos (templatefile onde há variáveis, file() nos demais).
  namespace_raw = file("${local.manifests_path}/namespace.yaml")
  configmap_raw = file("${local.manifests_path}/configmap.yaml")
  postgres_raw  = file("${local.manifests_path}/postgres.yaml")
  netpol_raw    = file("${local.manifests_path}/network-policy.yaml")
  pdb_raw       = file("${local.manifests_path}/pod-disruption-budget.yaml")

  secret_raw = templatefile("${local.manifests_path}/secret.yaml", {
    db_password = var.db_password
    jwt_secret  = var.jwt_secret
  })
  app_raw = templatefile("${local.manifests_path}/app-escalavel.yaml", {
    app_image = var.app_image
  })

  # Split de YAML multi-documento. Prefixa "\n" para que um "---" no início do
  # arquivo vire um separador limpo "\n---\n" (senão o primeiro documento sairia
  # com um "---" solto no começo). Blocos vazios são descartados.
  namespace_docs = [for d in split("\n---\n", "\n${local.namespace_raw}") : trimspace(d) if trimspace(d) != ""]
  configmap_docs = [for d in split("\n---\n", "\n${local.configmap_raw}") : trimspace(d) if trimspace(d) != ""]
  secret_docs    = [for d in split("\n---\n", "\n${local.secret_raw}") : trimspace(d) if trimspace(d) != ""]
  postgres_docs  = [for d in split("\n---\n", "\n${local.postgres_raw}") : trimspace(d) if trimspace(d) != ""]
  app_docs       = [for d in split("\n---\n", "\n${local.app_raw}") : trimspace(d) if trimspace(d) != ""]
  policy_docs = concat(
    [for d in split("\n---\n", "\n${local.netpol_raw}") : trimspace(d) if trimspace(d) != ""],
    [for d in split("\n---\n", "\n${local.pdb_raw}") : trimspace(d) if trimspace(d) != ""],
  )
}

resource "kubectl_manifest" "namespace" {
  count      = length(local.namespace_docs)
  yaml_body  = local.namespace_docs[count.index]
  depends_on = [kind_cluster.this]
}

resource "kubectl_manifest" "configmap" {
  count      = length(local.configmap_docs)
  yaml_body  = local.configmap_docs[count.index]
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "secret" {
  count      = length(local.secret_docs)
  yaml_body  = local.secret_docs[count.index]
  depends_on = [kubectl_manifest.namespace]
}

# Banco de dados: aplicado depois do config/secret. wait_for_rollout = true faz
# o Terraform esperar o StatefulSet ficar Ready (readinessProbe = pg_isready)
# antes de seguir — assim a app abaixo só sobe com o banco aceitando conexões.
resource "kubectl_manifest" "postgres" {
  count            = length(local.postgres_docs)
  yaml_body        = local.postgres_docs[count.index]
  wait_for_rollout = true
  depends_on       = [kubectl_manifest.configmap, kubectl_manifest.secret]
}

# Aplicação: só depois do banco pronto e da imagem carregada no cluster.
# wait_for_rollout = true faz o apply esperar o Deployment ficar disponível
# (readinessProbe = /actuator/health/readiness), ou seja, app de pé e conectada.
resource "kubectl_manifest" "app" {
  count            = length(local.app_docs)
  yaml_body        = local.app_docs[count.index]
  wait_for_rollout = true
  depends_on       = [kubectl_manifest.postgres, null_resource.load_image]
}

resource "kubectl_manifest" "policies" {
  count      = length(local.policy_docs)
  yaml_body  = local.policy_docs[count.index]
  depends_on = [kubectl_manifest.app]
}
