# Convenção de observabilidade

O projeto usa New Relic para acompanhar o cluster EKS `tech-challenge`, as APIs e o processamento de eventos de `os-service`, `billing-service` e `execution-service`.

## Coleta e identificação

As aplicações escrevem logs JSON no stdout. O New Relic Logging coleta esses registros dos contêineres. O agente Java fornece APM, traces e decoração local dos logs; seu encaminhamento próprio de logs fica desabilitado para evitar duplicação da coleta.

Cada serviço tem um recurso `Instrumentation`, com `NEW_RELIC_APP_NAME` igual a `os-service`, `billing-service` ou `execution-service`. A seleção combina namespace, rótulo `app` e nome do contêiner, conforme [instrumentation.yaml](../k8s/newrelic/instrumentation.yaml). Os componentes de coleta ficam em [values.yaml](../k8s/newrelic/values.yaml).

O workflow manual [Deploy New Relic](../.github/workflows/deploy-newrelic.yml) usa os secrets `AWS_CREDENTIALS` e `NEW_RELIC_LICENSE_KEY` do Environment `prod`. Ele instala o bundle e aplica a instrumentação. A chave de ingestão fica nos Secrets Kubernetes `newrelic-license` e `newrelic-key-secret`, conforme o componente que a utiliza. A injeção do agente ocorre na criação dos pods; a instalação do bundle não reinicia as aplicações.

Nos logs coletados do cluster, `container_name` identifica o serviço, `namespace_name` identifica o namespace e `cluster_name` identifica o cluster. No APM, a identificação é `appName`. As consultas de logs dos três serviços usam o nome do contêiner, sem presumir um namespace compartilhado.

## Campos de correlação

| Campo | Significado |
|---|---|
| `service` ou `container_name` | Serviço de origem; `container_name` é acrescentado pela coleta Kubernetes. |
| `correlationId` | ID da OS como texto, usado para reunir sua jornada. |
| `orderId` | ID numérico da OS nos registros de negócio. |
| `eventId` | UUID de um evento de integração, preservado nas reentregas. |
| `sagaEventType` | Tipo do evento nos registros de SAGA emitidos por `OrdemDeServicoEventLogger` do OS. |
| `operation` | Operação realizada, como recebimento, publicação ou processamento. |
| `outcome` ou `result` | Resultado daquela operação. |
| `serviceOrderEventType` / `executionEventType` | Categoria do registro de negócio no OS / execution. |
| `fromStatus`, `toStatus`, `occurredAt` | Estados envolvidos e momento da transição. |
| `errorType` | Classificação da falha nos registros que a informam. |

Os campos variam conforme a operação; logs de transição podem ter `orderId` sem `eventId`. `trace.id` e `span.id`, quando presentes, relacionam o registro à transação instrumentada. Uma OS pode atravessar vários traces por causa das filas e da outbox; a correlação de negócio usa `correlationId`, `orderId` e `eventId`.

## Formatos dos serviços

| Serviço | Registros emitidos |
|---|---|
| OS | Publicação e consumo em `message`, nos formatos `[SNS PUBLISHER] {json}` e `[SQS LISTENER] {json}`, com `eventId`, `eventType`, `operation` e `outcome` dentro do JSON. Também emite registros de negócio com `serviceOrderEventType`, `sagaEventType` e `result`. |
| Billing | Atributos JSON separados para `service`, `correlationId`, `orderId`, `eventId`, `eventType`, `operation` e `outcome`. Registra recebimento, processamento, duplicidade, publicação, compensação e falhas. |
| Execution | Atributos JSON separados para recebimento e operações do trabalho, com `operation` e `outcome`; transições e falhas usam `executionEventType`. O recebimento inclui `correlationId`, `eventId` e `eventType`. A publicação SNS bem-sucedida não gera um registro próprio de log. |

`eventType` é um nome reservado do New Relic e é descartado quando enviado como atributo principal de um log. No OS, o valor dentro do texto JSON de `message` continua acessível por `aparse` e `jparse`, e os registros complementares usam `sagaEventType`. Em billing e execution, a consulta por tipo depende da informação preservada em outros campos ou no texto; o atributo principal `eventType` não é uma dimensão pesquisável. O campo `type` do envelope SNS/SQS pertence ao contrato de integração e é independente desse tratamento dos logs. [Restrições do New Relic](https://docs.newrelic.com/docs/logs/log-api/log-event-data/).

## Consulta da jornada

Esta consulta reúne os registros de uma OS nos três serviços. O filtro por `orderId` também encontra registros de negócio sem `correlationId`.

```sql
FROM Log
SELECT timestamp, container_name, level, message,
       correlationId, orderId, eventId, sagaEventType,
       operation, outcome, result, fromStatus, toStatus
WHERE cluster_name = 'tech-challenge'
  AND container_name IN (
    'os-service', 'billing-service', 'execution-service'
  )
  AND (correlationId = '20' OR orderId = 20)
SINCE 24 hours ago
LIMIT MAX
```

Para uma mensagem específica, o filtro é `eventId = '<UUID>'`. A busca por `message LIKE '%<UUID>%'` complementa registros com identificadores dentro do texto. No dashboard, o período selecionado também influencia os resultados.

## Interpretação dos resultados

- **Recebimento:** o listener recebeu a mensagem; isso não confirma o processamento de negócio.
- **Processamento:** o resultado pertence à operação registrada. No OS, o log de consumo confirmado é emitido após a transação do handler.
- **Publicação:** `publicado` no OS e `aceito_broker` no billing indicam aceite do envio pelo broker, sem confirmar o processamento no destino.
- **Compensação:** o resultado descreve a operação local; o significado de `PAGAMENTO_ESTORNADO` está definido na [SAGA](saga.md#falhas-e-compensações).

`count(*)` mede registros de log; `uniqueCount(eventId)` mede IDs distintos no conjunto consultado. Um mesmo evento pode produzir vários registros e aparecer em mais de um serviço. A ausência de um log não comprova ausência do evento, e o cadastro do serviço no APM não comprova consumo das filas.

## Sinais operacionais

O acompanhamento combina transações, latência e erros do APM; CPU, memória, réplicas e eventos do Kubernetes; e logs de publicação, consumo, transições e falhas da SAGA.

O OS expõe em `/actuator/prometheus` as métricas Micrometer `os.eventos.publicados`, `os.eventos.consumidos`, `os.saga.transicoes` e `os.outbox.pendentes`. A coleta Prometheus é independente do agente APM e requer descoberta e scrape do endpoint. Backlog, idade das mensagens e DLQs são métricas do SQS, acessíveis no CloudWatch ou pela integração AWS do New Relic.

As mensagens são legíveis em português brasileiro. Credenciais, tokens e payloads completos de integração ficam fora dos registros de observabilidade.
