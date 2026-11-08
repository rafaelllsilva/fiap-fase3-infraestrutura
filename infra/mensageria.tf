# =============================================================================
# Mensageria compartilhada: tópicos SNS e filas SQS do os-service, billing-service e execution-service
# =============================================================================
#
# Cada serviço publica no seu próprio tópico e consome uma fila por serviço de origem:
#
#   os-events        -> billing-service-os-events,        execution-service-os-events
#   billing-events   -> os-service-billing-events,        execution-service-billing-events
#   execution-events -> os-service-execution-events,      billing-service-execution-events
#
# Os nomes são o contrato com as aplicações (variáveis de ambiente dos ConfigMaps de cada serviço).
# As aplicações usam queue-not-found-strategy=fail e não sobem se as filas não existirem.

# --- Tópicos e filas ---------------------------------------------------------
locals {
  servicos_mensageria = ["os", "billing", "execution"]

  # Uma fila para cada par (consumidor, origem) com consumidor != origem: 6 filas.
  # Nome da fila: <consumidor>-service-<origem>-events. Tópico de origem: <origem>-events.
  filas = {
    for par in setproduct(local.servicos_mensageria, local.servicos_mensageria) :
    "${par[0]}_${par[1]}" => {
      consumidor = par[0]
      origem     = par[1]
      nome       = "${par[0]}-service-${par[1]}-events"
    }
    if par[0] != par[1]
  }
}

resource "aws_sns_topic" "eventos" {
  for_each = toset(local.servicos_mensageria)

  name = "${each.key}-events"
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.filas

  name                      = "${each.value.nome}-dlq"
  message_retention_seconds = 1209600 # 14 dias, para dar tempo de investigar e reprocessar
}

resource "aws_sqs_queue" "fila" {
  for_each = local.filas

  name = each.value.nome

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}

# --- Integração SNS -> SQS ---------------------------------------------------
# Permite que somente o tópico de origem envie mensagens para a sua fila.
data "aws_iam_policy_document" "fila" {
  for_each = local.filas

  statement {
    sid       = "PermitirEnvioDoSns"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.fila[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.eventos[each.value.origem].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "fila" {
  for_each = local.filas

  queue_url = aws_sqs_queue.fila[each.key].id
  policy    = data.aws_iam_policy_document.fila[each.key].json
}

# Assina cada fila no tópico do serviço de origem. raw_message_delivery: as aplicações leem o envelope
# JSON direto, sem o wrapper do SNS.
resource "aws_sns_topic_subscription" "fila" {
  for_each = local.filas

  topic_arn            = aws_sns_topic.eventos[each.value.origem].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.fila[each.key].arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.fila]
}
