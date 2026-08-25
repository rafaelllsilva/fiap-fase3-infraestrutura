# fiap-fase3-infraestrutura

Infraestrutura do **Tech Challenge Fase 3 (FIAP)**.

O Terraform em `infra/` provisiona um cluster **Amazon EKS** (VPC com subnets
públicas/privadas, NAT Gateway, node group gerenciado e repositório ECR), publica a imagem
da aplicação no ECR e aplica os manifestos de `k8s/` no cluster — o deploy inteiro sai de
um `terraform apply`, sem `kubectl` manual na pipeline.

```
infra/     Terraform (VPC, EKS, addons, node group, ECR, deploy dos manifestos)
k8s/       manifestos aplicados no cluster
  ├── namespace.yaml
  ├── database/   Postgres (configmap, secret, StatefulSet+Service, network policy)
  └── app/        app Spring (secret, Deployment+Service+HPA, network policy, PDB)
```

## Pré-requisitos

| Ferramenta | Versão | Para quê |
| --- | --- | --- |
| Terraform | >= 1.10.0 | exigido pelo locking nativo do backend S3 (`use_lockfile`) |
| AWS CLI | v2 | credenciais, `eks get-token`, login no ECR |
| Docker | recente | build e push da imagem |
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

## 1. Build da imagem Docker (plataforma amd64)

**Este repositório não tem Dockerfile** — a imagem é buildada no repositório da aplicação.
O Terraform apenas faz `docker tag` + `docker push` de uma imagem que já precisa existir
localmente (`null_resource.push_image`).

Os nós do EKS são `AL2023_x86_64_STANDARD` / `t3.small`, ou seja **linux/amd64**. Num Mac
Apple Silicon o `docker build` sem `--platform` produz `linux/arm64`, e o containerd do nó
recusa o pull com `no match for platform in manifest: not found` → `ImagePullBackOff`.
Por isso a plataforma é obrigatória:

```bash
# no repositório da aplicação
docker build --platform linux/amd64 -t tech-challenge-app:local .

# conferir antes de seguir — precisa imprimir amd64
docker image inspect tech-challenge-app:local --format '{{.Architecture}}/{{.Os}}'
```

Num runner de CI amd64 o `--platform` é redundante, mas não atrapalha.

---

## 2. Provisionar o ambiente com o Terraform

Os `.tf` ficam em `infra/`, não na raiz. Use `-chdir=infra` em todos os comandos.

```bash
terraform -chdir=infra init       # backend S3 já hardcoded em infra/backend.tf
terraform -chdir=infra fmt -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Um provisionamento do zero leva **~15–20 min** (control plane EKS + NAT Gateway + node
group), mais alguns minutos nos `wait_for_rollout` do Postgres e da aplicação.

### Variáveis

Os defaults em `infra/variables.tf` são valores de teste. Sobrescreva via `TF_VAR_*`:

```bash
export TF_VAR_app_image="tech-challenge-app:local"
export TF_VAR_db_password="..."     # sensitive
export TF_VAR_jwt_secret="..."      # sensitive, mínimo 32 caracteres
```

Principais defaults: `aws_region=us-east-1`, `cluster_name=tech-challenge`,
`kubernetes_version=1.36`, `node_instance_type=t3.small`, `node_desired_size=2`,
`ecr_repository_name=tech-challenge-app`, `lab_role_name=LabRole`.

### Republicar a imagem depois de um rebuild

`null_resource.push_image` tem `triggers = { image = var.app_image, repo = ... }`. Rebuildar
localmente **não muda nenhum dos dois**, então o Terraform considera o recurso atualizado e
não republica no ECR. Para forçar:

```bash
terraform -chdir=infra apply -replace=null_resource.push_image
```

Em CI, o caminho melhor é passar uma tag única por build
(`TF_VAR_app_image=tech-challenge-app:<git-sha>`): a tag entra no trigger e cada build
republica sozinho.

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

Durante a rotação dos nós (`max_unavailable = 1`, um nó por vez) a aplicação continua de pé
graças às 2 réplicas e ao PodDisruptionBudget, mas o `postgres-0` é réplica única sem PDB:
ele é despejado e reagendado, e a app entra em CrashLoopBackOff até o banco voltar. É
esperado e se resolve sozinho. Se o `postgres-0` ficar `Pending`, veja se é conflito de AZ
do volume EBS — `kubectl describe pod postgres-0 -n tech-challenge` procurando
`volume node affinity conflict`.

### Destruir

O cluster tem custo contínuo (control plane EKS + NAT Gateway + EC2), diferente do Kind
efêmero que o projeto usava antes. Ao terminar os testes:

```bash
terraform -chdir=infra destroy
```

---

## 3. Conectar o kubectl ao cluster EKS

```bash
aws eks update-kubeconfig --region us-east-1 --name tech-challenge
kubectl get nodes
kubectl get pods -n tech-challenge
```

O mesmo comando sai pronto como output do Terraform:

```bash
terraform -chdir=infra output configure_kubectl
```

> **O endpoint muda toda vez que o cluster é recriado.** Um kubeconfig antigo falha com
> `dial tcp: lookup <hash>.us-east-1.eks.amazonaws.com: no such host` — não é rede nem
> permissão, é só endpoint velho. Rode o `update-kubeconfig` de novo.

---

## 4. Acessar a API (port-forward + token)

O `spring-app-service` é **ClusterIP**: não há Ingress nem Load Balancer, então a API não
tem rota pública. O acesso é por port-forward:

```bash
kubectl port-forward -n tech-challenge svc/spring-app-service 8080:80
```

A API fica em `http://localhost:8080`. Verificação rápida:

```bash
curl -s http://localhost:8080/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}
```

### Obter um token JWT

Todas as rotas sob `/api`, exceto o login, exigem `Authorization: Bearer <token>` e
respondem **403** sem ele. O token vem de `POST /api/auth/login`, e o campo da resposta é
`accessToken`:

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"login":"<usuario>","senha":"<senha>"}' | jq -r .accessToken)

curl -s http://localhost:8080/api/cliente -H "Authorization: Bearer $TOKEN"
```

A resposta do login traz `accessToken`, `role` e `expiresIn`. Para criar um usuário:
`POST /api/auth/usuario` com `{"login","senha","role","clienteId"}`.

### Explorar os contratos

```
http://localhost:8080/swagger-ui/index.html     # Swagger UI
http://localhost:8080/v3/api-docs               # OpenAPI (JSON)
```

Recursos disponíveis sob `/api`: `cliente`, `veiculo`, `peca`, `tipoPeca`, `servico`,
`tipo-servico` e `ordemDeServico` (incluindo as transições de estado da ordem e
adicionar/remover peças e serviços).

### Expor publicamente

Não está configurado, e exigiria **duas** mudanças juntas: trocar o `spring-app-service`
para `type: LoadBalancer` **e** ajustar a NetworkPolicy `app-security-policy`, que hoje só
aceita ingresso de `ipBlock: 10.0.0.0/8` na porta 8080 — sem isso o Load Balancer sobe mas
a API responde timeout. Um Load Balancer também é cobrado por hora enquanto existir.

---

## 5. Comandos de diagnóstico

```bash
# Visão geral do namespace
kubectl get pods,pvc,svc -n tech-challenge -o wide

# Acompanhar em tempo real (útil durante o apply)
kubectl get pods -n tech-challenge -w

# Por que um pod não sobe — os eventos ficam no fim da saída
kubectl describe pod -n tech-challenge -l app=spring-app

# Logs do container atual
kubectl logs -n tech-challenge -l app=spring-app --tail=100

# Logs da encarnação ANTERIOR — indispensável em CrashLoopBackOff,
# porque o container atual costuma estar em backoff, sem logs novos
kubectl logs -n tech-challenge <pod> --previous --tail=200

# Eventos do namespace, mais recentes por último
kubectl get events -n tech-challenge --sort-by=.lastTimestamp

# StorageClasses (a coluna DEFAULT importa: sem default o PVC do Postgres fica Pending)
kubectl get storageclass

# HPA e métricas (depende do addon metrics-server)
kubectl get hpa -n tech-challenge
```

Conferir a arquitetura da imagem publicada — comando decisivo em `ImagePullBackOff`:

```bash
aws ecr batch-get-image --repository-name tech-challenge-app --region us-east-1 \
  --image-ids imageTag=local \
  --accepted-media-types "application/vnd.oci.image.index.v1+json" \
    "application/vnd.oci.image.manifest.v1+json" \
  --query 'images[0].imageManifest' --output text | python3 -m json.tool
```

Precisa aparecer `"architecture": "amd64"`. A entrada `"unknown"` é o manifesto de
attestation do BuildKit, não uma plataforma faltando.

```bash
# Arquitetura dos nós — precisa bater com a da imagem
aws eks describe-nodegroup --cluster-name tech-challenge --nodegroup-name default \
  --region us-east-1 --query 'nodegroup.{amiType:amiType,instanceTypes:instanceTypes}'

# Saúde de um addon
aws eks describe-addon --cluster-name tech-challenge --addon-name aws-ebs-csi-driver \
  --region us-east-1 --query 'addon.{status:status,health:health}'
```

**Referência completa em [`comandos-diagnostico-eks.md`](comandos-diagnostico-eks.md)** —
inclui um caminho alternativo que consulta a API do cluster via `curl` sem escrever em
`~/.kube/config` (útil quando o kubeconfig está apontando para um cluster já destruído), e
o mapa da cadeia de causa dos erros mais comuns.

### Ler um erro de `wait_for_rollout`

Um erro do Terraform no `wait_for_rollout` quase nunca é sobre o Terraform — ele é o
**último elo** de uma cadeia. Exemplo real deste projeto:

```
StorageClass default ausente
  -> PVC do Postgres fica Pending
  -> postgres-0 não é escalonado
  -> postgres-service fica sem endpoints
  -> Flyway da app recebe "Connection refused" e o container sai com exit 1
  -> pods em CrashLoopBackOff, Deployment nunca fica Available
  -> Terraform: "context deadline exceeded"
```

Comece pelo pod que não fica `Ready`, leia os logs com `--previous`, e suba até a causa.
