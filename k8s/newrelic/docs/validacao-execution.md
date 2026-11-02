# Validar o execution-service no New Relic

Este roteiro valida a instrumentação do execution no EKS, sem alterar seu código. OS/billing e a SAGA integrada serão validados quando estiverem disponíveis.

## 1. Preparar o ambiente e instalar a instrumentação

- O banco do execution e as filas SQS devem estar disponíveis. A aplicação precisa de credenciais válidas e `JWT_SECRET` compatível com o emissor dos tokens.
- Na infraestrutura, o Environment `prod` precisa de `AWS_CREDENTIALS` vigente e `NEW_RELIC_LICENSE_KEY` do tipo **Ingest - License**.
- Após incorporar este PR, executar **Actions → Deploy New Relic → Run workflow**, na `main`. A workflow cria os namespaces, atualiza os Secrets e instala o bundle `8.0.22`, preservando o agente Java `9.4.0` fixado por digest.
- A workflow valida a instalação do coletor/operador e o schema do manifest no servidor. Ela **não reinicia o execution**: depois de concluir, fazer novo deploy pelo fluxo do repositório execution, para criar pods com o agente.

A configuração seleciona somente namespace `tech-challenge`, rótulo `app=execution-service` e contêiner `execution-service`. Ela atualiza o recurso existente `newrelic-instrumentation`, substituindo a seleção do monólito. OS e billing serão adicionados por configurações próprias.

## 2. Conferir saúde e injeção

Com AWS CLI e kubectl autenticados no ambiente:

```bash
aws eks update-kubeconfig --region us-east-1 --name tech-challenge
kubectl rollout status deployment/execution-service -n tech-challenge --timeout=5m
kubectl get pods -n tech-challenge -l app=execution-service
kubectl get instrumentation newrelic-instrumentation -n newrelic
kubectl get pods -n tech-challenge -l app=execution-service \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.initContainers[*].name}{"\n"}{end}'
```

Todos os novos pods devem estar saudáveis e conter `nri-java--execution-service`. Ausência desse init container indica pod anterior à instrumentação ou seletor incompatível.

Escolher um pod da lista e conferir apenas as variáveis não sensíveis:

```bash
POD_EXECUTION='<nome-do-pod>'
kubectl exec -n tech-challenge "$POD_EXECUTION" -c execution-service -- \
  printenv NEW_RELIC_APP_NAME NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED \
  NEW_RELIC_APPLICATION_LOGGING_LOCAL_DECORATING_ENABLED
```

Esperado, nessa ordem: `execution-service`, `false`, `true`. Não executar `printenv` sem filtro nem exibir Secrets.

## 3. Gerar tráfego

Em um terminal, manter aberto:

```bash
kubectl port-forward -n tech-challenge deployment/execution-service 18080:8080
```

Em outro:

```bash
curl --fail-with-body http://localhost:18080/actuator/health/readiness
for i in {1..10}; do
  curl -fsS http://localhost:18080/v3/api-docs > /dev/null || break
done
```

Readiness deve retornar `UP`. O OpenAPI gera tráfego HTTP sem depender de JWT; as rotas de health podem ser ignoradas pelo APM, por isso não usar apenas probes como evidência de transações.

Para exercitar a API autenticada, usar a collection do execution com token válido de `MECANICO`, `ATENDENTE` ou `GERENTE` e executar `GET /api/execucao/fila`. Não colocar JWT, senha ou chave de ingestão na collection versionada.

## 4. Conferir APM e logs

Após alguns minutos, abrir **APM & Services → execution-service**. Confirmar transações HTTP, tempo de resposta e acesso aos traces disponíveis. Uma primeira consulta no Query Builder:

```sql
FROM Transaction
SELECT count(*), average(duration)
WHERE appName = 'execution-service'
SINCE 30 minutes ago
```

Em Logs, filtrar por `namespace_name = 'tech-challenge'` e `container_name = 'execution-service'`. Confirmar que esses atributos existem nos registros ingeridos; se o coletor usar outro nome, selecionar o equivalente no painel de atributos.

```sql
FROM Log
SELECT timestamp, level, message, orderId, executionEventType
WHERE namespace_name = 'tech-challenge'
  AND container_name = 'execution-service'
SINCE 30 minutes ago
LIMIT 100
```

O stdout continua sendo coletado pelo New Relic Logging. O encaminhamento do agente Java está desligado e a decoração local ligada para evitar duplicação. Confirmar que um log identificável aparece uma única vez e que logs emitidos dentro de uma transação instrumentada se ligam ao APM. Logs fora de transações podem não ter trace.

## 5. Conferir uma OS e o caminho assíncrono

Com uma OS de teste já existente no execution, executar uma transição válida pela collection e consultar seus logs adicionando `AND orderId = <id-da-os>` à consulta anterior. O execution registra `orderId`; não exigir `correlationId` como novo campo.

Conferir `executionEventType = 'execution_status_changed'`, `fromStatus` e `toStatus`, e comparar com o resultado persistido na API. A duração de transição recebe zero fixo na versão revisada e não é uma medida válida para o painel.

Para SQS/outbox, usar um evento válido do fluxo de teste e verificar quais operações e ligações aparecem no APM. A instalação do agente não comprova um trace contínuo entre requisição, outbox agendada e consumidor. Registrar os trechos capturados; a correlação por OS continua válida mesmo quando há traces separados. Não retirar mensagens da fila de saída apenas para inspecioná-las.

## Critério de conclusão

Guardar evidências de pods saudáveis com agente, transações em `execution-service`, um log sem duplicação e a transição da mesma OS na API/Logs. Se só houver instalação do operador, sem dados da aplicação, a validação ainda não terminou.

Se a aplicação não iniciar, conferir banco, SQS, credenciais e eventos do pod antes de atribuir a falha ao APM. Se faltar telemetria, conferir seletores, novo deploy, nome APM, conectividade de saída e chave de ingestão. Reverter este PR e recriar os pods remove a instrumentação aplicada por ele; retirar somente o agente também pode ser feito removendo seu recurso `Instrumentation` e recriando os pods pelo deploy do execution.

Referências: [auto-attach Kubernetes](https://docs.newrelic.com/docs/kubernetes-pixie/kubernetes-integration/installation/k8s-agent-operator/) e [logs Java com coletor externo](https://docs.newrelic.com/docs/logs/logs-context/java-configure-logs-context-all/).
