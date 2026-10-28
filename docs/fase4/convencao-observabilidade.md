# Observabilidade dos três serviços

**Proposta para discussão do grupo — 27/10/2026.**

## Objetivo

Continuar usando o **New Relic da Fase 3**, agora identificando cada serviço e permitindo acompanhar uma OS do início ao fim.

## Padrão básico de logs

Manter logs JSON no console. As mensagens legíveis devem estar em português brasileiro; preservar as chaves técnicas existentes para não quebrar consultas.

| Campo | Uso |
|---|---|
| `service` | Identificar OS, billing ou execution. |
| `correlationId` | ID da OS como texto, igual nos três serviços. |
| `orderId` | ID da OS, preservando o campo já usado nos logs. |
| `eventId` e `eventType` | Identificar o evento, quando o log envolver mensageria. |
| `operation` e `outcome` | Indicar a ação e seu resultado. |

Exemplo proposto, com campos que ainda precisam ser adotados:

```json
{
  "service": "execution-service",
  "correlationId": "10",
  "orderId": 10,
  "eventId": "501ddf7b-228e-497c-8b4f-84124f0d35dd",
  "eventType": "PAGAMENTO_CONFIRMADO",
  "operation": "processar_evento",
  "outcome": "confirmado",
  "message": "Pagamento processado e peças reservadas"
}
```

Registrar principalmente: mudança de status confirmada, evento processado ou duplicado, falha de publicação/processamento e resultado da compensação. Publicar um evento não significa que o outro serviço já o processou. Não registrar sucesso de negócio antes do commit nem incluir credenciais ou payloads completos nos logs.

## O que ajustar no New Relic

1. **Identificar os três serviços separadamente.** A configuração atual ainda seleciona `tech-challenge-app`; ela precisa reconhecer `execution-service` e, depois, os nomes acordados para OS e billing.
2. **Validar a coleta dos logs JSON**, evitando enviar o mesmo log pelo agente Java e pelo coletor Kubernetes ao mesmo tempo.
3. **Testar o rastreamento entre os serviços**, principalmente na passagem por SQS e pela outbox. Ter APM no HTTP não garante que esse caminho já esteja ligado.

`correlationId` acompanha a OS inteira. O trace acompanha operações instrumentadas; uma OS pode passar por vários traces enquanto aguarda aprovação ou pagamento.

O execution já possui logs JSON. Porém, a duração de transição ainda recebe zero fixo no código revisado: não usar esse campo como medida real em um painel antes de corrigir.

## O mínimo para a entrega

- Cada serviço visível no New Relic com seu próprio nome.
- Logs pesquisáveis pelo mesmo `correlationId` nos três serviços.
- Um painel simples com saúde dos serviços, erros e falhas da SAGA.
- Evidências de uma OS concluída e de uma falha com compensação.

A frente de observabilidade cuida da configuração central, painel e evidências. Cada responsável adiciona os campos e pontos de log no seu serviço.
