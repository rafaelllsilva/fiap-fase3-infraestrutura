# Comandos de diagnóstico no EKS

Referência dos comandos usados para investigar os pods do cluster `tech-challenge`
(namespace `tech-challenge`) durante a depuração do deploy — `ImagePullBackOff`,
`CrashLoopBackOff` e PVC preso em `Pending`.

Valores usados ao longo do documento: região `us-east-1`, cluster `tech-challenge`,
namespace `tech-challenge`, label da app `app=spring-app`.

---

## 0. Pré-requisitos

As credenciais do AWS Academy Learner Lab expiram junto com a sessão do lab. Antes de
qualquer coisa, confirme que ainda estão válidas:

```bash
aws sts get-caller-identity
```

Se retornar `ExpiredToken`, renove a sessão no lab e reexporte
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.

---

## 1. Caminho normal: `kubectl`

O cluster é recriado com frequência e **o endpoint muda a cada recriação**. Um kubeconfig
antigo falha com `dial tcp: lookup <hash>.gr7.us-east-1.eks.amazonaws.com: no such host` —
não é problema de rede nem de permissão, é só o endpoint velho. Regerar:

```bash
aws eks update-kubeconfig --region us-east-1 --name tech-challenge
kubectl get nodes
```

Com o kubeconfig em dia:

```bash
# Visão geral do namespace
kubectl get pods,pvc,svc -n tech-challenge -o wide

# Acompanhar em tempo real (útil durante o apply)
kubectl get pods -n tech-challenge -w

# Por que um pod não sobe — eventos ficam no fim da saída
kubectl describe pod -n tech-challenge -l app=spring-app

# Logs do container ATUAL
kubectl logs -n tech-challenge -l app=spring-app --tail=100

# Logs da encarnação ANTERIOR — indispensável em CrashLoopBackOff,
# porque o container atual costuma estar em backoff, sem logs novos
kubectl logs -n tech-challenge <nome-do-pod> --previous --tail=200

# Eventos do namespace, mais recentes por último
kubectl get events -n tech-challenge --sort-by=.lastTimestamp

# StorageClasses do cluster (a coluna DEFAULT importa)
kubectl get storageclass
```

---

## 2. Caminho alternativo: API do cluster via `curl`

Foi o caminho usado na depuração, por dois motivos: o kubeconfig local estava apontando
para um endpoint morto, e essa forma **não escreve nada** em `~/.kube/config` — serve para
inspecionar o cluster sem alterar a configuração da máquina.

Monte endpoint e token uma vez por sessão de shell (o token do `aws eks get-token` vale
~15 minutos; refaça quando começar a dar `401`):

```bash
EP=$(aws eks describe-cluster --name tech-challenge --region us-east-1 \
      --query 'cluster.endpoint' --output text)
TOK=$(aws eks get-token --cluster-name tech-challenge --region us-east-1 \
      --query 'status.token' --output text)
```

> O `-k` do curl abaixo pula a verificação do certificado do servidor. É aceitável para
> diagnóstico pontual; para algo mais sério, extraia o CA e use `--cacert`:
> `aws eks describe-cluster --name tech-challenge --region us-east-1 --query 'cluster.certificateAuthority.data' --output text | base64 -d > /tmp/eks-ca.crt`

### Logs de um pod

```bash
# Container atual
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/pods/<nome-do-pod>/log?container=spring-app-container&tailLines=120"

# Encarnação anterior (equivalente ao --previous do kubectl)
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/pods/<nome-do-pod>/log?container=spring-app-container&previous=true&tailLines=200"
```

Foi assim que apareceu a causa real do `CrashLoopBackOff` da app:

```
FlywaySqlUnableToConnectToDbException: Unable to obtain connection from database:
Connection to postgres-service.tech-challenge.svc.cluster.local:5432 refused.
```

### Estado de todos os pods do namespace

```bash
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/pods" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d['items']:
    st=p['status']
    print(p['metadata']['name'],'|phase=',st.get('phase'),'|node=',p['spec'].get('nodeName'))
    for c in st.get('containerStatuses',[]):
        print('    ready=',c.get('ready'),'restarts=',c.get('restartCount'))
        print('    state=',json.dumps(c.get('state')))
"
```

Filtrando por label, troque a URL por:
`"$EP/api/v1/namespaces/tech-challenge/pods?labelSelector=app%3Dspring-app"`
(`%3D` é o `=` escapado).

Foi essa saída que mostrou o `ImagePullBackOff` com a mensagem do containerd:

```
failed to pull and unpack image "...tech-challenge-app:local":
no match for platform in manifest: not found
```

### Por que um pod não é escalonado

```bash
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/pods/postgres-0" | python3 -c "
import json,sys; d=json.load(sys.stdin)
for c in d['status'].get('conditions',[]):
    print(c['type'],c['status'],c.get('reason'),'-',c.get('message'))
"
```

### Eventos de um objeto específico

```bash
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/events?fieldSelector=involvedObject.name%3Dpostgres-storage-postgres-0" \
  | python3 -c "
import json,sys; d=json.load(sys.stdin)
for e in d['items']: print(e.get('type'),e.get('reason'),'-',e.get('message'))
"
```

### Endpoints de um Service

Serviço `ClusterIP` sem endpoints devolve `Connection refused` a quem tenta conectar — é o
que fazia o Flyway da app falhar:

```bash
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/endpoints/postgres-service" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('subsets'))"
# subsets = None  ->  nenhum pod pronto por trás do Service
```

### PVCs e StorageClasses

```bash
# PVCs do namespace
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/api/v1/namespaces/tech-challenge/persistentvolumeclaims" | python3 -c "
import json,sys; d=json.load(sys.stdin)
for p in d['items']:
    print(p['metadata']['name'],'phase=',p['status'].get('phase'),
          'sc=',p['spec'].get('storageClassName'),'volume=',p['spec'].get('volumeName'))
"

# StorageClasses do cluster — conferir provisioner e qual é a default
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/apis/storage.k8s.io/v1/storageclasses" | python3 -c "
import json,sys; d=json.load(sys.stdin)
for s in d.get('items',[]):
    ann=s['metadata'].get('annotations',{})
    print(s['metadata']['name'],'| provisioner=',s.get('provisioner'),
          '| default=',ann.get('storageclass.kubernetes.io/is-default-class'))
"
```

### Estado de um Deployment

```bash
curl -sk -H "Authorization: Bearer $TOK" \
  "$EP/apis/apps/v1/namespaces/tech-challenge/deployments/spring-app-deployment" | python3 -c "
import json,sys; d=json.load(sys.stdin); s=d.get('status',{})
print('replicas:',s.get('replicas'),'ready:',s.get('readyReplicas'),'available:',s.get('availableReplicas'))
for c in s.get('conditions',[]): print(' ',c['type'],c['status'],c.get('reason'),'-',c.get('message'))
"
```

---

## 3. Comandos AWS de apoio

Nem tudo se diagnostica de dentro do cluster.

```bash
# O cluster existe? Qual o endpoint atual?
aws eks list-clusters --region us-east-1
aws eks describe-cluster --name tech-challenge --region us-east-1 \
  --query 'cluster.{endpoint:endpoint,status:status,version:version}'

# Arquitetura dos nós — precisa bater com a da imagem publicada no ECR
aws eks describe-nodegroup --cluster-name tech-challenge --nodegroup-name default \
  --region us-east-1 \
  --query 'nodegroup.{amiType:amiType,instanceTypes:instanceTypes,status:status,scaling:scalingConfig}'

# Saúde de um addon (ex.: o driver EBS CSI)
aws eks describe-addon --cluster-name tech-challenge --addon-name aws-ebs-csi-driver \
  --region us-east-1 --query 'addon.{status:status,version:addonVersion,health:health}'
```

### Conferir a arquitetura da imagem no ECR

Este foi o comando decisivo no `ImagePullBackOff`: mostra para quais plataformas a tag
realmente existe. Se não houver `amd64` e os nós forem `AL2023_x86_64_STANDARD`, o
containerd recusa o pull.

```bash
aws ecr batch-get-image --repository-name tech-challenge-app --region us-east-1 \
  --image-ids imageTag=local \
  --accepted-media-types \
    "application/vnd.oci.image.index.v1+json" \
    "application/vnd.oci.image.manifest.v1+json" \
    "application/vnd.docker.distribution.manifest.list.v2+json" \
    "application/vnd.docker.distribution.manifest.v2+json" \
  --query 'images[0].imageManifest' --output text | python3 -m json.tool
```

A entrada com `"architecture": "unknown"` é o manifesto de attestation do BuildKit, não uma
plataforma — pode ignorar.

```bash
# Histórico de pushes e último pull registrado (confirma se o nó chegou ao ECR)
aws ecr describe-images --repository-name tech-challenge-app --region us-east-1

# Arquitetura da imagem local, antes de empurrar
docker image inspect tech-challenge-app:local --format '{{.Architecture}}/{{.Os}}'
```

> Num Mac Apple Silicon, `docker build` sem `--platform` gera `linux/arm64` e o pull falha
> nos nós amd64. Builde com `docker build --platform linux/amd64 -t tech-challenge-app:local .`

---

## 4. Cadeia de causa observada nesta depuração

Útil como mapa: um erro do Terraform no `wait_for_rollout` quase nunca é sobre o Terraform.

```
StorageClass default ausente no cluster
  -> PVC postgres-storage-postgres-0 fica Pending
     ("no persistent volumes available for this claim and no storage class is set")
  -> postgres-0 não é escalonado ("unbound immediate PersistentVolumeClaims")
  -> Service postgres-service fica sem endpoints (subsets = null)
  -> Flyway da app recebe "Connection refused" e o container sai com exit 1
  -> pods spring-app entram em CrashLoopBackOff
  -> Deployment nunca fica Available (ProgressDeadlineExceeded)
  -> kubectl_manifest.app_deployment roda o wait_for_rollout até o deadline
  -> Terraform: "client rate limiter Wait returned an error: context deadline exceeded"
```

Regra prática: comece pelo fim da cadeia (o pod que não fica `Ready`), leia os logs com
`--previous`, e suba até a causa. A mensagem do Terraform é sempre o último elo, nunca o
primeiro.
