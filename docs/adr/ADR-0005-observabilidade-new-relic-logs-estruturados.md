# ADR-0005 — Observabilidade com New Relic e logs estruturados

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Implementado mediante execução da workflow de observabilidade |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `fiap-fase3-infraestrutura`                   |
| RFC relacionada | Não há RFC dedicada; requisito de observabilidade descrito na Seção 7 do `DOCUMENTACAO_TECNICA_FASE_3.md` |

## Contexto

A fase exige visibilidade sobre latência, consumo de CPU/memória, saúde, uptime, logs correlacionados, dashboards e alertas para falhas de ordens de serviço. Sem uma solução de observabilidade centralizada, esses sinais ficariam dispersos entre `kubectl`, logs de container isolados e métricas não correlacionadas, dificultando diagnóstico e resposta a incidentes.

## Decisão

Instalar o `nri-bundle` (New Relic) no cluster EKS e usar auto-instrumentação Java (auto-attach do agente APM) para coletar métricas de Kubernetes, logs, APM e traces da aplicação. A aplicação escreve logs estruturados no formato Logstash/JSON no console, permitindo que o New Relic Logging colete e correlacione logs de containers automaticamente.

A instalação não é automática no pipeline principal: é executada por uma workflow manual (`Deploy New Relic`) que depende da variável de ambiente `NEW_RELIC_LICENSE_KEY` configurada no environment `prod`. Dashboards e alertas são mantidos manualmente no produto New Relic, incluindo o dashboard `Tech Challenge - Observability`.

Para métricas de negócio (volume de OS, tempo médio entre transições de status, falhas de processamento), a aplicação emite eventos estruturados após o commit da transação através de `OrdemDeServicoEventLogger`, com campos como `serviceOrderEventType`, `orderId`, `status`, `fromStatus`, `toStatus`, `durationInPreviousStatusMs`, `operation`, `errorType` e `occurredAt`.

## Consequências

**Positivas:**
- Centraliza métricas técnicas (latência, throughput, erros, CPU, memória) e métricas de negócio (volume e tempo de ciclo de OS) em uma única ferramenta.
- Logs estruturados em JSON facilitam consultas e correlação no New Relic sem parsing adicional.
- A auto-instrumentação Java reduz o esforço de instrumentação manual de código para tracing e APM.

**Negativas / trade-offs aceitos:**
- Por depender de uma workflow manual, a observabilidade não é garantida por padrão em todo novo ambiente — é preciso lembrar de executá-la e configurar a license key.
- Dashboards e alertas são mantidos manualmente na interface do New Relic, sem versionamento como código (não há "dashboards as code" nesta decisão).
- A correlação de trace depende do agente APM e não é um campo explícito emitido pelo `OrdemDeServicoEventLogger`, exigindo validação em ambiente real de que o New Relic está de fato ingerindo e correlacionando os eventos.

## Alternativas descartadas

- **Stack própria de observabilidade (Prometheus + Grafana + Loki) autogerenciada no EKS**: descartada por exigir mais esforço operacional de manutenção e armazenamento de séries temporais e logs, incompatível com o escopo e o tempo do desafio.
- **Ausência de ferramenta centralizada, apenas `kubectl logs` e métricas do Metrics Server**: descartada por não atender ao requisito da fase de dashboards, alertas e correlação de logs/traces.
- **Uso exclusivo de CloudWatch (AWS nativo)**: descartado em favor do New Relic por oferecer APM com auto-instrumentação Java e dashboards mais completos para o escopo da aplicação.

## Referências

- [`Diagrama de Componentes`](../c4/C4-Diagrama-de-Componentes.md) 
