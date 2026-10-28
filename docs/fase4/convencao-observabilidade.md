# Observabilidade dos três serviços

**Diretriz de implementação — 28/10/2026.**

## Objetivo

Usar o New Relic da Fase 3 para identificar os serviços e acompanhar uma OS. A configuração central fica na infraestrutura. OS e billing adotam o padrão abaixo; o execution mantém seus logs atuais.

## Padrão de logs

Manter JSON no console e mensagens legíveis em português brasileiro. Preservar as chaves técnicas já existentes.

| Campo em OS e billing | Uso |
|---|---|
| `service` | `os-service` ou `billing-service`. |
| `correlationId` | ID da OS como texto. |
| `orderId` | ID da OS, compatível com o campo já usado no execution. |
| `eventId` e `eventType` | Evento envolvido no processamento. |
| `operation` e `outcome` | Ação e resultado. |

Exemplo de log do OS ao consumir uma reserva:

```json
{
  "service": "os-service",
  "correlationId": "10",
  "orderId": 10,
  "eventId": "501ddf7b-228e-497c-8b4f-84124f0d35dd",
  "eventType": "ESTOQUE_RESERVADO",
  "operation": "processar_evento",
  "outcome": "confirmado",
  "message": "Reserva de estoque registrada no histórico da OS"
}
```

Registrar transições após commit, eventos processados/duplicados, falhas de publicação/processamento e resultado do estorno. O aceite de uma publicação não significa processamento confirmado no destino. Não registrar credenciais nem payloads completos.

## Execution e New Relic

O execution já registra `orderId`, transições e falhas em JSON. Para correlacioná-lo com os demais, pesquisar `correlationId = '10'` **ou** `orderId = 10`. Sua identidade é obtida pelos metadados de Kubernetes/APM. Não exigir novos campos de log no execution para esta integração.

Infra configura entidades APM separadas: `os-service`, `billing-service` e `execution-service`, usando os rótulos/contêineres correspondentes no namespace `tech-challenge`. A seleção antiga de `tech-challenge-app` será substituída.

Manter a coleta por stdout no coletor Kubernetes e evitar encaminhamento duplicado pelo agente Java. Validar a auto-instrumentação nos pods e na passagem por SQS/outbox. `correlationId` liga a jornada de negócio; uma OS pode atravessar vários traces. A evidência deve mostrar os trechos realmente capturados pelo agente, sem presumir continuidade automática.

A duração de transição no execution recebe zero fixo na versão revisada. Essa medida ficará fora dos painéis desta entrega, preservando o código existente.

## Entrega da observabilidade

- Três serviços visíveis no New Relic, cada um com seu nome.
- Logs da mesma OS encontrados por correlação ou `orderId`.
- Painel simples com saúde, erros e falhas da SAGA.
- Evidências de sucesso e falha com estorno, incluindo logs da Lambda de roteamento.

A implementação e a coleta de evidências ainda serão executadas. Esta convenção define o trabalho e não declara uma integração já validada.
