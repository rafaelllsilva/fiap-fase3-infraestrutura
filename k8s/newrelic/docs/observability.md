# Observabilidade - Tech Challenge Fase 3

Este documento descreve a observabilidade do ambiente de produção do Tech Challenge Fase 3: Amazon EKS `tech-challenge`, aplicacao Spring Boot e PostgreSQL no namespace `tech-challenge`.

> Segredos nao devem ser versionados. A chave **Ingest - License** do New Relic deve existir somente como Kubernetes Secret ou secret da pipeline.

> Este repositório é responsável pela infraestrutura compartilhada: VPC, EKS, ECR, namespace e StorageClass. A aplicação e o banco de dados são implantados e mantidos pelos respectivos repositórios, embora ambos sejam observados neste documento.

## Objetivo

A solução deve permitir a visualização, em tempo real, de:

- latência, vazão, erros e traces da API;
- consumo de CPU e memoria dos workloads Kubernetes;
- logs da aplicação e do PostgreSQL;
- disponibilidade de pods e replicas;
- falhas no processamento de ordens de serviço.

Os dashboards sao criados manualmente no New Relic.

## Arquitetura de observabilidade

```text
Clientes
   |
API Gateway (quando provisionado)
   |
Amazon EKS: tech-challenge
   |-- namespace tech-challenge
   |   |-- Spring Boot (Deployment + HPA)
   |   `-- PostgreSQL (StatefulSet + PVC)
   `-- namespace newrelic
       |-- nri-bundle: metricas, eventos e logs Kubernetes
       `-- K8s APM auto-attach: agente Java nos pods Spring
   |
New Relic: Kubernetes, APM, Logs, Traces, Dashboards e Alerts
```

## Componentes configurados

| Componente | Funcao |
| --- | --- |
| `nri-bundle` | Coleta metricas, eventos e logs do cluster. |
| New Relic Logging | Encaminha logs dos containers ao New Relic. |
| K8s APM auto-attach | Injeta o agente Java sem alterar o Dockerfile. |
| `Instrumentation` | Seleciona apenas os pods Spring Boot. |
| APM Java | Coleta transacoes, latencia, erros, dependencias e traces. |

## Instalação da integração Kubernetes

A instalação e atualização oficial do New Relic é feita manualmente pela workflow GitHub **Deploy New Relic** (`.github/workflows/deploy-newrelic.yml`). Ela usa o Environment `prod`, configura o acesso ao EKS canônico `tech-challenge`, cria ou atualiza o namespace e o Secret, instala o bundle e aplica o auto-attach Java. Não executar esses passos a partir de máquinas locais.

Pré-requisito: cadastrar uma chave **Ingest - License** válida no GitHub Environment `prod` como o secret `NEW_RELIC_LICENSE_KEY`. A chave nunca deve ser versionada em `values.yaml`, manifests, variáveis Terraform, state, documentação ou logs. A workflow cria o Secret Kubernetes `newrelic-license` no namespace `newrelic` sem imprimir seu valor.

A workflow falha antes da instalação caso não exista node `Ready`; escale ou recupere o node group e execute-a novamente. Ela não reinicia a aplicação: após a instalação do auto-attach, faça um novo deploy da aplicação pelo fluxo do repositório da aplicação para que os novos pods recebam o agente Java.

### Seleção para APM

O recurso `Instrumentation` fica no namespace `newrelic` e seleciona somente os pods Spring:

```yaml
namespaceLabelSelector:
  matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values: [tech-challenge]
podLabelSelector:
  matchExpressions:
    - key: app
      operator: In
      values: [spring-app]
```

Essa seleção evita instrumentar o StatefulSet PostgreSQL.

## Segurança da chave do New Relic

- Usar exclusivamente uma chave **Ingest - License**.
- Nunca inserir a chave em `values.yaml`, manifests, commits, screenshots ou mensagens.
- Manter nome, namespace e chave do Kubernetes Secret consistentes com Helm e `Instrumentation`.
- Em CI/CD, usar secrets do provedor e criar/atualizar o Kubernetes Secret durante o deploy.

## Validação operacional

### Kubernetes e HPA

```bash
kubectl get nodes
kubectl get pods -n tech-challenge
kubectl get hpa -n tech-challenge
kubectl top pods -n tech-challenge
```

### Confirmar o auto-attach Java

```bash
kubectl get pods -n tech-challenge --show-labels
kubectl get pod <pod-spring> -n tech-challenge \
  -o jsonpath='{.spec.initContainers[*].name}'
```

Após o novo deploy da aplicação, valide especificamente o init container esperado:

```bash
kubectl get pod <pod-spring> -n tech-challenge \
  -o jsonpath='{.spec.initContainers[*].name}' | tr ' ' '\n' | grep -x 'nri-java--spring-app-container'
```

O comando deve retornar `nri-java--spring-app-container`. Se não retornar, confirme os labels `app=spring-app` no pod e o namespace `tech-challenge`.

### Gerar uma transação de teste

Em um terminal:

```bash
kubectl port-forward -n tech-challenge service/spring-app-service 8080:80
```

Em outro terminal:

```bash
for i in {1..50}; do
  curl -fsS http://localhost:8080/actuator/health > /dev/null
  sleep 1
done
```

Apos alguns minutos, a transacao deve aparecer em **APM & Services** no servico `spring-app-deployment`.

## Dashboard

Nome: `Tech Challenge - Observability`.

| Painel | Objetivo |
| --- | --- |
| API latency | Tempo medio de resposta. |
| API throughput | Requisicoes por minuto. |
| API error rate | Percentual de transacoes com erro. |
| Spring pods - CPU | CPU por pod Spring Boot. |
| Spring pods - memory | Memoria por pod Spring Boot. |
| Spring deployment - desired vs available replicas | Disponibilidade e HPA. |
| Recent logs - tech-challenge | Logs recentes da aplicacao e banco. |

### Consultas NRQL

#### Latencia

```sql
FROM Transaction
SELECT average(duration) * 1000 AS 'Average response time (ms)'
WHERE appName = 'spring-app-deployment' AND transactionType = 'Web'
TIMESERIES
```

#### Vazao

```sql
FROM Transaction
SELECT rate(count(*), 1 minute) AS 'Requests per minute'
WHERE appName = 'spring-app-deployment' AND transactionType = 'Web'
TIMESERIES
```

#### Taxa de erros

```sql
FROM Transaction
SELECT percentage(count(*), WHERE error IS true) AS 'Error rate (%)'
WHERE appName = 'spring-app-deployment' AND transactionType = 'Web'
TIMESERIES
```

#### CPU

```sql
FROM K8sContainerSample
SELECT average(cpuUsedCores) AS 'CPU cores'
WHERE clusterName = 'tech-challenge'
  AND namespaceName = 'tech-challenge'
  AND containerName = 'spring-app-container'
FACET podName TIMESERIES
```

#### Memoria

```sql
FROM K8sContainerSample
SELECT average(memoryWorkingSetBytes) / 1024 / 1024 AS 'Memory (MiB)'
WHERE clusterName = 'tech-challenge'
  AND namespaceName = 'tech-challenge'
  AND containerName = 'spring-app-container'
FACET podName TIMESERIES
```

#### Replicas

```sql
FROM K8sDeploymentSample
SELECT latest(podsDesired) AS 'Desired', latest(podsAvailable) AS 'Available'
WHERE clusterName = 'tech-challenge'
  AND namespaceName = 'tech-challenge'
  AND deploymentName = 'spring-app-deployment'
TIMESERIES
```

#### Logs recentes

```sql
FROM Log
SELECT timestamp, level, message
WHERE namespace_name = 'tech-challenge'
LIMIT 20
```

## Telemetria de negocio pendente

Os paineis tecnicos nao substituem as metricas de negocio solicitadas. Os logs JSON estruturados da aplicacao sao coletados do stdout do container pelo New Relic Logging; nao adicionar SDK New Relic a aplicacao apenas para logs. A aplicacao deve emitir logs JSON e/ou eventos customizados quando:

1. uma ordem de servico e criada;
2. uma ordem muda de status;
3. ocorre falha de processamento ou integracao.

Campos minimos recomendados:

```text
serviceOrderEventType
orderId
fromStatus
toStatus
transitionDurationMs
timestamp
traceId
```

Valores esperados para `serviceOrderEventType`:

```text
service_order_created
service_order_status_changed
service_order_processing_failed
```

Depois da implementacao, acrescentar ao dashboard:

- volume diario de ordens de servico criadas;
- tempo medio de transicao por status, especialmente Diagnostico, Execucao e Finalizacao;
- quantidade de falhas no processamento de ordens.

## Alertas pendentes

Depois que os eventos de negocio forem implementados, criar:

1. alerta para qualquer `serviceOrderEventType = 'service_order_processing_failed'` em cinco minutos;
2. alerta de taxa de erro da API acima do limite definido pelo time, por exemplo 5% por cinco minutos;
3. alerta de indisponibilidade do endpoint publico depois do API Gateway.

Um `kubectl port-forward` serve para validacao local, mas nao para uptime externo.

## Capacidade do cluster

O ambiente usa tres nos `t3.medium` (2 vCPU e 4 GiB de memoria por no). A mudanca ocorreu porque `t3.small` ficou sem memoria e slots de pods quando a observabilidade e os rollouts foram habilitados.

O node group permite expansao manual ate quatro nos. Sem Cluster Autoscaler, o HPA aumenta replicas da aplicacao, mas nao cria novos nos automaticamente.

## Evidencias para demonstracao

Registrar screenshots ou gravacao de:

1. nodes, pods e HPA saudaveis;
2. Kubernetes no New Relic com CPU, memoria e workloads;
3. uma transacao e trace no APM Java;
4. logs filtrados por `namespace_name:tech-challenge`;
5. dashboard completo;
6. alertas configurados e, se possivel, um disparo controlado.

## Responsabilidades

| Responsavel | Acao |
| --- | --- |
| Infraestrutura | Manter EKS, Terraform, capacidade dos nos e manifests sem segredos. |
| Aplicacao | Emitir logs JSON e eventos de negocio para OS, transicoes e falhas. |
| SRE/Documentacao | Manter dashboard, alertas, evidencias, validacoes e este documento. |
| Serverless/API Gateway | Disponibilizar endpoint publico para monitoramento de uptime. |
