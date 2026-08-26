# fiap-fase3-infraestrutura

Infraestrutura do **Tech Challenge Fase 3 (FIAP)**.

O Terraform em `infra/` provisiona um cluster **Amazon EKS** — VPC com subnets
públicas/privadas, NAT Gateway, addons, managed node group e repositório ECR — mais os
recursos de cluster compartilhados (namespace e StorageClass default).

**Este repositório não implanta o banco de dados nem a aplicação.** Esses componentes têm
ciclo de vida próprio e vivem em repositórios separados, que se integram a este lendo os
outputs do state remoto em S3 — ver [Integração com os outros
repositórios](#integração-com-os-outros-repositórios).

```
infra/
├── versions.tf     bloco terraform{} — required_version, required_providers
├── backend.tf      bloco terraform{} — backend "s3"
├── providers.tf    providers aws e kubernetes
├── main.tf         VPC, EKS + addons, node group, ECR, namespace, StorageClass
├── variables.tf    input variables
└── outputs.tf      contrato de integração com os outros repositórios
script-criar-backend.sh   bootstrap manual do bucket S3 do state
```

## Pré-requisitos

| Ferramenta | Versão | Para quê |
| --- | --- | --- |
| Terraform | >= 1.10.0 | exigido pelo locking nativo do backend S3 (`use_lockfile`) |
| AWS CLI | v2 | credenciais, `eks get-token` |
| kubectl | compatível com 1.36 | acesso ao cluster |

Credenciais AWS válidas na cadeia padrão do SDK. Numa conta do **AWS Academy Learner Lab**
a sessão expira junto com o lab — confirme antes de começar:

```bash
aws sts get-caller-identity
```

Se retornar `ExpiredToken`, renove a sessão e reexporte `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN`.

O backend do state (bucket S3 `archtechs-infra`) é bootstrap manual, feito uma única vez —
ver `script-criar-backend.sh`. Ele não é criado por este Terraform (problema de ovo-e-galinha).

---

## 1. Provisionar o ambiente

Os `.tf` ficam em `infra/`, não na raiz. Use `-chdir=infra` em todos os comandos.

```bash
terraform -chdir=infra init       # backend S3 já hardcoded em infra/backend.tf
terraform -chdir=infra fmt -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Um provisionamento do zero leva **~15–20 min** (control plane EKS + NAT Gateway + node
group). Ao final, `terraform -chdir=infra output` imprime tudo o que os outros
repositórios precisam.

### Variáveis

Os defaults em `infra/variables.tf` cobrem o uso normal; sobrescreva via `TF_VAR_*` quando
necessário. Não há mais nenhuma variável `sensitive` neste módulo — senha do banco e chave
JWT saíram junto com o deploy do workload.

Principais defaults: `aws_region=us-east-1`, `cluster_name=tech-challenge`,
`kubernetes_version=1.36`, `node_instance_type=t3.small`, `node_desired_size=2`,
`namespace=tech-challenge`, `ecr_repository_name=tech-challenge-app`,
`lab_role_name=LabRole`, `cluster_admin_role_arns=[]`.

`cluster_admin_role_arns` só é necessária fora do Learner Lab: no lab todos os pipelines
usam a mesma role de sessão que criou o cluster, que já é admin por
`bootstrap_cluster_creator_admin_permissions`. Se as pipelines dos repositórios de app e
banco rodarem com outra IAM role, liste os ARNs dela aqui para receberem uma EKS Access
Entry de admin.

### Subir a versão do Kubernetes

`var.kubernetes_version` alimenta **o cluster e o node group**, então mudar a variável sobe
os dois no mesmo apply. Os addons são o passo à parte.

> **Um minor por vez.** O EKS não aceita pular versões no upgrade: da 1.34 para a 1.36 são
> dois ciclos completos, com a 1.35 no meio. A restrição vale só para cluster existente — um
> cluster criado do zero pode nascer direto em qualquer versão suportada. Desde julho de
> 2026 há rollback para o minor anterior dentro de 7 dias, mas conte com ele como saída de
> emergência, não como plano.

```bash
# 1. conferir o que a AWS oferece e o status de suporte de cada versão
aws eks describe-cluster-versions --region us-east-1 \
  --query 'clusterVersions[].{v:clusterVersion,status:status,fimPadrao:endOfStandardSupportDate}' \
  --output table

# 2. control plane + nós
terraform -chdir=infra plan -out=tfplan   # espere update in-place, nunca replace do cluster
terraform -chdir=infra apply tfplan

# 3. addons: como addon_version não é declarado (a AWS escolhe o default da
#    versão do cluster), só a recriação faz cada um pegar a versão nova
terraform -chdir=infra apply \
  -replace=aws_eks_addon.kube_proxy \
  -replace=aws_eks_addon.vpc_cni \
  -replace=aws_eks_addon.coredns \
  -replace=aws_eks_addon.ebs_csi_driver \
  -replace=aws_eks_addon.metrics_server
```

> **Cuidado com o upgrade pela metade.** `version` no node group e `addon_version` nos
> addons são `Optional + Computed`: sem valor no config, o Terraform lê o que existe na AWS
> e não propõe diferença. Foi por isso que `version = var.kubernetes_version` foi declarado
> explicitamente no node group — sem ele, um upgrade atualizaria só o control plane e
> deixaria os nós para trás com o apply terminando limpo.

Durante a rotação dos nós (`max_unavailable = 1`, um nó por vez) os workloads são despejados
e reagendados. Avise os repositórios de app e banco antes de um upgrade.

### Destruir

O cluster tem custo contínuo (control plane EKS + NAT Gateway + EC2).

```bash
terraform -chdir=infra destroy
```

> **Destrua os workloads primeiro.** Rode o `destroy` dos repositórios de banco e de
> aplicação antes deste. Se o namespace for removido daqui com workloads dentro, o
> `terraform destroy` deles falhará por não achar mais os recursos, e volumes EBS órfãos
> podem sobrar sendo cobrados.

---

## 2. Conectar o kubectl ao cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name tech-challenge
kubectl get nodes
```

O mesmo comando sai pronto como output do Terraform:

```bash
terraform -chdir=infra output configure_kubectl
```

> **O endpoint muda toda vez que o cluster é recriado.** Um kubeconfig antigo falha com
> `dial tcp: lookup <hash>.us-east-1.eks.amazonaws.com: no such host` — não é rede nem
> permissão, é só endpoint velho. Rode o `update-kubeconfig` de novo.

---

## Integração com os outros repositórios

Os outputs de `infra/outputs.tf` são o **contrato público** deste módulo. Os repositórios
de banco de dados e de aplicação os leem do state remoto:

```hcl
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "archtechs-infra"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}

provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", local.infra.cluster_name,
      "--region", local.infra.aws_region,
    ]
  }
}
```

### Regras de convivência

- **`key` distinta por repositório.** Todos usam o mesmo bucket `archtechs-infra`, mas cada
  root module precisa da própria chave de state — ex.: `database/terraform.tfstate` e
  `app/terraform.tfstate`. Reusar `terraform.tfstate` sobrescreveria o state da
  infraestrutura.
- **Não recrie o que já existe.** O namespace e a StorageClass são criados aqui; use
  `local.infra.namespace` e `local.infra.storage_class_name` em vez de declarar os seus. Um
  segundo `create` do mesmo namespace falha por conflito.
- **Acesso ao cluster.** Se a pipeline consumidora rodar com uma IAM role diferente da que
  criou o cluster, adicione o ARN dela em `var.cluster_admin_role_arns` **deste** repositório
  e reaplique — senão o provider `kubernetes` do consumidor recebe `Unauthorized`.

### O que cada output resolve

| Consumidor | Outputs que usa |
| --- | --- |
| Providers `kubernetes`/`kubectl`/`helm` | `cluster_endpoint`, `cluster_certificate_authority_data`, `cluster_name`, `aws_region` |
| Repositório do banco | `namespace`, `storage_class_name`, `vpc_cidr_block` (ipBlock das NetworkPolicies) |
| Repositório da aplicação | `namespace`, `ecr_repository_url`, `ecr_repository_name`, `ecr_registry_id`, `vpc_cidr_block` |
| Operação | `configure_kubectl`, `node_group_name`, `cluster_version` |

### Publicando a imagem no ECR

O repositório ECR é provisionado aqui, mas o build e o push são da pipeline da aplicação:

```bash
REPO=$(terraform -chdir=infra output -raw ecr_repository_url)

docker build --platform linux/amd64 -t "$REPO:$GIT_SHA" .
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REPO"
docker push "$REPO:$GIT_SHA"
```

> **`--platform linux/amd64` é obrigatório.** Os nós são `AL2023_x86_64_STANDARD` /
> `t3.small`. Num Mac Apple Silicon o `docker build` sem `--platform` produz `linux/arm64`,
> e o containerd do nó recusa o pull com `no match for platform in manifest: not found` →
> `ImagePullBackOff`. Confira com
> `docker image inspect <img> --format '{{.Architecture}}/{{.Os}}'`.

### Acoplamento entre banco e aplicação

A aplicação lê `SPRING_DATASOURCE_USERNAME`/`_PASSWORD` do ConfigMap `db-config` e do Secret
`db-credentials`, que pertencem ao banco. Com os dois em repositórios separados, o
repositório do banco deve ser o dono desses recursos e expor nos próprios outputs o nome do
Secret/ConfigMap e o host/porta do Service — o repositório da aplicação os consome por um
segundo `terraform_remote_state` apontando para a `key` do banco.

---

## 3. Diagnóstico do cluster

```bash
# Nós: precisam ficar Ready. STATUS NotReady costuma ser CNI ou kube-proxy.
kubectl get nodes -o wide

# Componentes de sistema (coredns, aws-node, kube-proxy, ebs-csi-*, metrics-server)
kubectl get pods -n kube-system

# StorageClasses — a coluna DEFAULT importa: sem default, todo PVC fica Pending
kubectl get storageclass

# metrics-server respondendo? Se der erro, todo HPA fica em <unknown>
kubectl top nodes

# Eventos do cluster, mais recentes por último
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

Do lado da AWS:

```bash
# Saúde do node group
aws eks describe-nodegroup --cluster-name tech-challenge --nodegroup-name default \
  --region us-east-1 --query 'nodegroup.{status:status,health:health,amiType:amiType,instanceTypes:instanceTypes}'

# Saúde de um addon (DEGRADED aqui é o que faz o apply falhar)
aws eks describe-addon --cluster-name tech-challenge --addon-name aws-ebs-csi-driver \
  --region us-east-1 --query 'addon.{status:status,health:health}'

# Quem tem acesso ao cluster
aws eks list-access-entries --cluster-name tech-challenge --region us-east-1
```

### Modo hibernação

Para períodos ociosos, escale o node group para zero em vez de destruir o cluster — o
control plane continua cobrando, mas EC2 e EBS dos nós zeram, e os volumes dos workloads
sobrevivem:

```bash
# Dormir
aws eks update-nodegroup-config --region us-east-1 --cluster-name tech-challenge \
  --nodegroup-name default --scaling-config minSize=0,maxSize=4,desiredSize=0

# Acordar (~3 min)
aws eks update-nodegroup-config --region us-east-1 --cluster-name tech-challenge \
  --nodegroup-name default --scaling-config minSize=0,maxSize=4,desiredSize=2
```

> **Acorde o cluster antes de qualquer `terraform apply`.** Com 0 nós, `coredns`,
> `aws-ebs-csi-driver` e `metrics-server` ficam `DEGRADED` e o apply falha nesses addons.
> Note também que `var.node_min_size` tem default 2: um apply depois de hibernar reverte o
> `minSize=0` acima.
