# Pontos para alinhar com o grupo

**Em aberto — 27/10/2026.**

Precisamos resolver estes cinco pontos para os serviços seguirem o mesmo fluxo. As sugestões abaixo ainda não são decisões aprovadas.

| Ponto | O que decidir | Quem alinha |
|---|---|---|
| **1. Entrega dos eventos** | Como `EXECUCAO_FALHOU` chegará a OS e billing? Hoje a saída do execution vai para `execution-events`. Sugestão: SNS com filas SQS separadas por consumidor. Alternativa: publicação confiável para cada destino. Os dois serviços não devem disputar a mesma fila esperando receber uma cópia cada. | Infra + responsáveis pelos serviços |
| **2. Aprovação do orçamento** | Quem recebe a aprovação e publica o evento? Sugestão: entrada pelo OS e evento `ORCAMENTO_APROVADO` para billing. Escolher um nome, pois o planejamento também cita `OS_APROVADA`. | OS + Billing |
| **3. Cancelamento e estorno** | Qual status a OS apresenta enquanto o estorno está pendente ou falhou? Quando pode ser considerado concluído? Também combinar se pagamento recusado permite nova tentativa. | OS + Billing + Execution |
| **4. Namespace** | Quem cria o namespace dos serviços? O Terraform deixou de criá-lo, mas o README ainda diz que é responsabilidade da infra. Hoje o CD do execution cria `tech-challenge`. Alinhar isso antes de ajustar o New Relic. | Infra + responsáveis pelo deploy |
| **5. Peças e preços** | Como billing identifica o preço de uma peça indicada pelo execution? Combinar uma referência ou mapeamento, sem acessar o banco do outro serviço. | Execution + Billing |

Depois de conversar, registrar a escolha e os nomes dos responsáveis aqui, atualizar os documentos afetados e seguir a implementação. Não precisamos de um processo formal de aprovação: apenas deixar o acordo claro para todos.

## Acordos do grupo

Preencher após o alinhamento:

| Ponto | Escolha e responsáveis |
|---|---|
| 1. Entrega dos eventos | A definir |
| 2. Aprovação do orçamento | A definir |
| 3. Cancelamento e estorno | A definir |
| 4. Namespace | A definir |
| 5. Peças e preços | A definir |
