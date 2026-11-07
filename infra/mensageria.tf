# =============================================================================
# Mensageria compartilhada: filas SQS do os-service, billing-service e execution-service
# =============================================================================
#
# Os serviços publicam direto nas filas (sem SNS). Cada serviço consome uma fila por tipo de evento,
# nomeada <consumidor>-<evento>. Toda fila tem uma DLQ (<fila>-dlq).
#
# Os nomes são o contrato com as aplicações (variáveis de ambiente dos ConfigMaps de cada serviço).
# As aplicações usam queue-not-found-strategy=fail e não sobem se as filas não existirem.
#
# A autorização de envio/consumo é por IAM (role dos nós, mesma conta), sem queue policy.

# --- Filas e DLQs ------------------------------------------------------------
locals {
  filas = toset([
    # execution-service
    "execution-os-criada",            # OS_CRIADA (os-service)
    "execution-pagamento-confirmado", # PAGAMENTO_CONFIRMADO (billing-service)
    "execution-os-cancelada",         # OS_CANCELADA (os-service)
    "execution-pagamento-estornado",  # PAGAMENTO_ESTORNADO (billing-service)

    # billing-service
    "billing-diagnostico-concluido", # DIAGNOSTICO_CONCLUIDO (execution-service)
    "billing-orcamento-aprovado",    # ORCAMENTO_APROVADO (os-service)
    "billing-execucao-falhou",       # EXECUCAO_FALHOU (execution-service)
    "billing-os-cancelada",          # OS_CANCELADA (os-service)

    # os-service
    "os-orcamento-gerado",      # ORCAMENTO_GERADO (billing-service)
    "os-pagamento-confirmado",  # PAGAMENTO_CONFIRMADO (billing-service)
    "os-pagamento-falhou",      # PAGAMENTO_FALHOU (billing-service)
    "os-pagamento-estornado",   # PAGAMENTO_ESTORNADO (billing-service)
    "os-diagnostico-concluido", # DIAGNOSTICO_CONCLUIDO (execution-service)
    "os-estoque-reservado",     # ESTOQUE_RESERVADO (execution-service)
    "os-execucao-iniciada",     # EXECUCAO_INICIADA (execution-service)
    "os-execucao-finalizada",   # EXECUCAO_FINALIZADA (execution-service)
    "os-execucao-falhou",       # EXECUCAO_FALHOU (execution-service)
  ])
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.filas

  name                      = "${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 dias, para dar tempo de investigar e reprocessar
}

resource "aws_sqs_queue" "fila" {
  for_each = local.filas

  name = each.key

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}
