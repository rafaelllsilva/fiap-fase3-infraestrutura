# Validar execution e OS no New Relic

Roteiro para conferir agente Java, APM e logs no EKS. A configuração do billing será incluída junto de seu deployment; a SAGA integrada exige validação própria.

## 1. Instalar ou atualizar a instrumentação

- Disponibilizar banco, mensageria e credenciais exigidos pelo deploy de cada serviço. O `JWT_SECRET` deve ser compatível com o emissor dos tokens.
- Na infraestrutura, configurar os secrets `AWS_CREDENTIALS` vigente e `NEW_RELIC_LICENSE_KEY` do tipo **Ingest - License** no Environment `prod`.
- Executar **Actions → Deploy New Relic → Run workflow** na branch com as correções. A execução antes do merge funciona porque esse workflow manual já existe na `main`; ela altera o mesmo ambiente EKS compartilhado.
- O workflow instala o bundle `8.0.22`, aplica os dois recursos `Instrumentation` e atualiza a chave nos namespaces `newrelic`, `tech-challenge` e `os-service`. O agente Java permanece na versão `9.4.0`, fixado por digest.
- Depois, executar o CD de cada serviço que precisa receber o agente ou uma nova chave. O workflow da infraestrutura não reinicia aplicações. A atualização do Secret só chega às variáveis de ambiente quando os pods são recriados.

| Serviço / nome APM | Namespace | Rótulo `app` / contêiner | Recurso `Instrumentation` em `newrelic` |
|---|---|---|---|
| `execution-service` | `tech-challenge` | `execution-service` | `newrelic-instrumentation` |
| `os-service` | `os-service` | `os-service` | `newrelic-instrumentation-os-service` |

O namespace selecionado deve corresponder ao deployment, mesmo quando seu nome difere do serviço.

## 2. Conferir saúde e injeção

Com AWS CLI e kubectl autenticados, escolher um serviço. Repetir o roteiro para o outro:

```bash
aws eks update-kubeconfig --region us-east-1 --name tech-challenge
SERVICO=execution-service
NAMESPACE=tech-challenge
# Para validar o OS, usar SERVICO=os-service e NAMESPACE=os-service.

kubectl rollout status deployment/"$SERVICO" -n "$NAMESPACE" --timeout=5m
kubectl get instrumentation -n newrelic
kubectl get pods -n "$NAMESPACE" -l "app=$SERVICO" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.initContainers[*].name}{"\n"}{end}'
kubectl get secret newrelic-key-secret -n "$NAMESPACE" -o name
```

Todos os novos pods devem estar saudáveis e conter `nri-java--execution-service` ou `nri-java--os-service`, conforme o serviço. Ausência desse init container indica pod anterior à instrumentação ou seletor incompatível.

Escolher um pod da lista e conferir somente variáveis não sensíveis:

```bash
POD_VALIDACAO='<nome-do-pod>'
kubectl exec -n "$NAMESPACE" "$POD_VALIDACAO" -c "$SERVICO" -- \
  printenv NEW_RELIC_APP_NAME NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED \
  NEW_RELIC_APPLICATION_LOGGING_LOCAL_DECORATING_ENABLED
```

Esperado: nome do serviço, `false`, `true`. Não executar `printenv` sem filtro nem exibir o conteúdo dos Secrets.

## 3. Gerar tráfego

No mesmo terminal, manter aberto:

```bash
kubectl port-forward -n "$NAMESPACE" deployment/"$SERVICO" 18080:8080
```

Em outro terminal:

```bash
curl --fail-with-body http://localhost:18080/actuator/health/readiness
for i in {1..10}; do
  curl -fsS http://localhost:18080/v3/api-docs > /dev/null || break
done
```

Readiness deve retornar `UP`. O OpenAPI gera tráfego sem JWT; não usar somente health probes como evidência de transações. Para operações de negócio, usar a collection do serviço com token válido, sem versionar credenciais.

## 4. Conferir APM e logs

Após alguns minutos, abrir **APM & Services** e conferir cada serviço. No Query Builder:

```sql
FROM Transaction
SELECT count(*), average(duration)
WHERE appName IN ('execution-service', 'os-service')
FACET appName
SINCE 30 minutes ago
```

Em Logs, filtrar pelo par namespace/contêiner da tabela. Confirmar os nomes dos atributos nos registros ingeridos; se o coletor usar nomes diferentes, selecionar os equivalentes:

```sql
FROM Log
SELECT timestamp, level, message, orderId, correlationId
WHERE (namespace_name = 'tech-challenge' AND container_name = 'execution-service')
   OR (namespace_name = 'os-service' AND container_name = 'os-service')
SINCE 30 minutes ago
LIMIT 100
```

O stdout é coletado pelo New Relic Logging, com encaminhamento pelo agente Java desligado e decoração local ligada. Conferir um log identificável sem duplicação e sua ligação ao APM quando emitido dentro de uma transação instrumentada. Logs fora de transações podem não ter trace.

## 5. Guardar evidências

Para cada serviço, registrar pods saudáveis com agente, transações APM e logs recentes. O sucesso do workflow da infraestrutura comprova a instalação do coletor/operador e a aceitação dos manifests; não comprova ingestão da telemetria da aplicação.

Ao exercitar uma OS de teste, comparar o resultado persistido na API com logs por `orderId` ou `correlationId`. No execution, conferir `executionEventType`, `fromStatus` e `toStatus`; a duração de transição recebe zero fixo na versão revisada e fica fora dos painéis.

SQS/outbox pode produzir traces separados: registrar os trechos realmente capturados e usar o ID da OS para correlacionar a jornada. Não retirar mensagens da fila de saída apenas para inspecioná-las.

Se faltar telemetria, conferir seletores, recriação dos pods, chave, conectividade e nome APM. Se a aplicação não iniciar, conferir também banco, mensageria, credenciais e eventos do pod. Para retirar um agente, remover somente o recurso `Instrumentation` correspondente e recriar os pods pelo CD do serviço; o coletor de logs continua instalado.

Referências: [auto-attach Kubernetes](https://docs.newrelic.com/docs/kubernetes-pixie/kubernetes-integration/installation/k8s-agent-operator/) e [logs Java com coletor externo](https://docs.newrelic.com/docs/logs/logs-context/java-configure-logs-context-all/).
