# Justificativa da divisão dos microsserviços e tecnologias utilizadas

Nov 17, 2026 · @Theo

## Contexto e objetivo

O monolito da oficina mecânica foi dividido em três microsserviços independentes — OS, Billing e Execution — porque a operação nacional, com várias filiais, exige resiliência, tolerância a falhas e consistência entre etapas críticas (criação da OS, aprovação, pagamento e execução).

O enunciado da Fase 4 pede, no mínimo, três serviços, cada um com repositório, infraestrutura e banco próprios, sem acesso direto ao banco de outro serviço, e um Saga Pattern com compensação em caso de falha. Este documento explica por que a divisão foi feita desta forma e por que cada tecnologia foi escolhida.

## Critérios da divisão

O corte segue quem é dono de cada dado e de cada decisão de negócio, e não as camadas técnicas da aplicação. Quatro critérios guiaram a divisão:

1. **Um dono por dado.** O OS Service é dono do status da ordem; o Billing, do orçamento e do dinheiro; o Execution, do diagnóstico, do estoque de peças e da fila de produção. Nenhum serviço lê o banco de outro: o que um precisa do outro chega dentro do evento.
2. **Fronteiras que já existem no negócio.** O enunciado descreve atendimento, diagnóstico, execução e cobrança como áreas que interagem. As três áreas sugeridas (OS, Billing, Execution) agrupam essas funções sem fragmentar o sistema em serviços pequenos demais.
3. **Falhas e integrações isoladas.** Só o Billing conhece o Mercado Pago, então trocar de provedor mexe em um serviço. Se um serviço sai do ar, as filas guardam as mensagens e ele as processa quando volta.
4. **Entrega e escala independentes.** Cada serviço tem repositório, pipeline, banco, Deployment e autoescalonamento (HPA) próprios, como o enunciado exige.

## Os três serviços

Cada serviço responde por uma etapa da jornada da OS e só altera os próprios dados; os outros dois só recebem fatos por evento.

| Serviço | É dono de | Banco | Publica | Consome |
| --- | --- | --- | --- | --- |
| OS Service | Ordem de serviço e seu histórico, clientes, veículos, login dos usuários internos | PostgreSQL (RDS), schema `os` | `OS_CRIADA`, `ORCAMENTO_APROVADO`, `ORCAMENTO_REJEITADO`, `OS_CANCELADA` | Eventos do Billing e do Execution |
| Billing Service | Orçamento, cobrança Pix no Mercado Pago, estorno, catálogo de preços de peças e serviços | DynamoDB (NoSQL) | `ORCAMENTO_GERADO`, `PAGAMENTO_CONFIRMADO`, `PAGAMENTO_FALHOU`, `PAGAMENTO_ESTORNADO` | `DIAGNOSTICO_CONCLUIDO`, `EXECUCAO_FALHOU`, `ORCAMENTO_APROVADO`, `ORCAMENTO_REJEITADO`, `OS_CANCELADA` |
| Execution Service | Diagnóstico, estoque de peças e reservas, fila de execução | PostgreSQL (RDS), schema `execution` | `DIAGNOSTICO_CONCLUIDO`, `ESTOQUE_RESERVADO`, `EXECUCAO_INICIADA`, `EXECUCAO_FINALIZADA`, `EXECUCAO_FALHOU` | `OS_CRIADA`, `OS_CANCELADA`, `PAGAMENTO_CONFIRMADO`, `PAGAMENTO_FALHOU`, `PAGAMENTO_ESTORNADO` |

Por que cada um é um serviço à parte:

- **OS Service.** É o único que decide o status da ordem. Os demais serviços não o alteram: publicam fatos (pagamento confirmado, execução finalizada) e o OS aplica a transição pela sua máquina de estados.
- **Billing Service.** Isola tudo que envolve dinheiro e o provedor externo: Pix, webhook e estorno. É o serviço com maior teto de autoescalonamento (até 10 réplicas, contra 4 nos outros dois).
- **Execution Service.** É dono do estoque e da fila de produção. A reserva de peças é tudo ou nada, e o mecânico consome a fila em ordem de chegada (FIFO), regras que não fazem sentido fora dele.

## Comunicação entre serviços

Os três serviços se falam apenas por eventos assíncronos em Amazon SNS e SQS; não há chamada REST entre eles. A jornada da OS é coordenada por uma **saga coreografada**: cada serviço reage ao evento de que precisa e publica o resultado do seu próprio domínio.

### Por que coreografia e não orquestração

- **São só três participantes e o fluxo é quase linear.** Um orquestrador seria um componente a mais, sem ganho real de clareza.
- **Sem ponto central de falha.** Se um serviço cai, os eventos esperam na fila e são processados quando ele volta. Um orquestrador fora do ar pararia todas as OS.
- **Baixo acoplamento.** Os serviços conhecem o contrato dos eventos, não as APIs uns dos outros. As compensações também são eventos (`PAGAMENTO_FALHOU`, `OS_CANCELADA`, `PAGAMENTO_ESTORNADO`).

SNS e SQS são serviços gerenciados da AWS, então não há broker para operar no cluster, e já trazem fan-out (um tópico, várias filas) e fila de mensagens mortas (DLQ).

### Tópicos e filas

Cada serviço publica só no próprio tópico. Cada consumidor tem uma fila por produtor, com DLQ de 14 dias de retenção, assinada com *raw message delivery* (o consumidor lê o envelope JSON direto, sem o wrapper do SNS). Tudo é provisionado no repositório de infraestrutura, não pelos serviços.

| Produtor | Tópico SNS | Filas SQS assinantes |
| --- | --- | --- |
| OS Service | `os-events` | `billing-service-os-events`, `execution-service-os-events` |
| Billing Service | `billing-events` | `os-service-billing-events`, `execution-service-billing-events` |
| Execution Service | `execution-events` | `os-service-execution-events`, `billing-service-execution-events` |

### Garantias de entrega

As filas são Standard, então a entrega é *pelo menos uma vez* e pode vir fora de ordem. Cada serviço trata isso do mesmo modo:

- **Outbox transacional.** O evento é gravado na mesma transação que muda o estado e um publicador o envia ao SNS. Assim o evento só existe se a mudança também existiu.
- **Consumidor idempotente.** O `eventId` é gravado na mesma transação do tratamento, então uma reentrega é ignorada.
- **Reentrega e DLQ.** Mensagem que falha volta à fila e, após cinco recebimentos, vai para a DLQ. Isso cobre também o evento que chega antes do seu pré-requisito.
- **Rastreio.** O `correlationId` é sempre o `osId`, presente nos eventos e nos logs JSON de todos os serviços.

### Falhas e compensações

Cada serviço compensa os efeitos nos próprios dados, com uma nova operação de negócio (liberar reserva, registrar estorno). Não há transação global para desfazer.

| Falha | Compensação |
| --- | --- |
| Orçamento rejeitado, ou cancelamento antes do pagamento | OS vai para `CANCELADA`; Billing encerra o orçamento e a cobrança pendente; Execution cancela o item e libera as reservas |
| Pagamento recusado | OS volta a `AGUARDANDO_APROVACAO`; ao atingir o limite de tentativas (padrão 3), vai para `CANCELADA` |
| Falta de estoque após o pagamento | Execution marca o item `FALHOU` e publica `EXECUCAO_FALHOU` (`SEM_ESTOQUE`); OS cancela; Billing registra o estorno e publica `PAGAMENTO_ESTORNADO` |
| Falha durante a execução | Execution libera as reservas e publica `EXECUCAO_FALHOU`; OS cancela; Billing aplica o mesmo estorno |

## Dados e infraestrutura

Cada serviço tem banco isolado, e a infraestrutura é dividida em repositórios independentes, para que o banco de um serviço possa ser criado ou alterado sem tocar nos outros.

### Bancos de dados

O projeto usa dois bancos relacionais e um não relacional, atendendo ao mínimo de um SQL e um NoSQL do enunciado.

| Serviço | Banco | Por que esta escolha |
| --- | --- | --- |
| OS Service | PostgreSQL (Amazon RDS) | Ordem, cliente, veículo e usuário são entidades ligadas entre si, que pedem integridade referencial e transações; o schema evolui por migrations Flyway |
| Execution Service | PostgreSQL (Amazon RDS) | A reserva de peças é tudo ou nada dentro de uma transação, e a fila de execução e a outbox dependem de consultas com bloqueio (`FOR UPDATE SKIP LOCKED`) |
| Billing Service | DynamoDB | O acesso é por chave: pela OS e, quando o webhook do Mercado Pago chega, pelo `paymentId` (índice secundário). Não há junções, e não há instância para dimensionar |

O RDS é gerenciado, e não um Postgres dentro de um pod do EKS, porque o banco tem ciclo de vida independente do cluster e ganha backup, patch, criptografia e credenciais no AWS Secrets Manager sem esforço operacional extra. O Security Group de cada banco libera acesso apenas ao cluster EKS.

### Entrada e autenticação

O Amazon API Gateway é a porta de entrada única: `/auth` vai para uma função Lambda, e `/os`, `/billing` e `/execution` vão para o Load Balancer (NLB) de cada serviço no EKS. O Mercado Pago também chama o webhook pela rota `/billing`.

O JWT tem dois emissores com o mesmo segredo, então qualquer serviço valida qualquer token sem consultar outro:

- **Lambda de autenticação:** recebe o CPF do cliente, valida o documento e emite o token com o papel `CLIENTE`.
- **OS Service:** faz o login por usuário e senha dos perfis internos (`GERENTE`, `ATENDENTE`, `MECANICO`).

### Repositórios e o que cada um provisiona

| Repositório | Provisiona | Ferramenta |
| --- | --- | --- |
| Infraestrutura | VPC, cluster EKS (Kubernetes 1.36), mensageria (SNS, SQS e DLQs) e coleta de observabilidade do New Relic | Terraform |
| Banco de dados | RDS PostgreSQL do OS e do Execution, tabela DynamoDB do Billing e credenciais no Secrets Manager; um workflow por serviço | Terraform |
| Serverless | Lambda de autenticação por CPF e API Gateway | AWS SAM (CloudFormation) |
| Cada serviço | Imagem Docker no ECR, manifestos Kubernetes e pipeline CI/CD próprios | GitHub Actions e `kubectl` |

No cluster, cada serviço roda em um namespace próprio, com pelo menos 2 réplicas, autoescalonamento por CPU e memória (HPA) e Pod Disruption Budget para manter ao menos uma réplica disponível durante atualizações.

## Tecnologias utilizadas

Os três serviços compartilham a mesma base tecnológica, e só o banco do Billing difere por necessidade do domínio. Isso reduz o custo de manter e de revisar o código entre os repositórios.

| Camada | Tecnologia | Por que foi escolhida |
| --- | --- | --- |
| Linguagem e framework | Java 21 (Amazon Corretto) e Spring Boot 4.0.5 | Mesma stack nos três serviços e continuidade com as fases anteriores; MVC, Data JPA, Security e Actuator cobrem API, persistência, segurança e probes de saúde |
| Organização do código | Clean Architecture (`domain`, `usecase`, `adapter`, `framework`) | As regras de negócio ficam sem dependência de framework, banco ou broker, o que facilita testar a saga em unidade |
| Mensageria | Amazon SNS e SQS (Spring Cloud AWS 4.0.2) | Gerenciados, sem broker para operar; fan-out por tópico e DLQ nativa sustentam a saga coreografada |
| Bancos | PostgreSQL 16 com Flyway; DynamoDB (AWS SDK v2) | Cada banco é o que melhor serve ao acesso do serviço (ver Dados e infraestrutura); Flyway versiona o schema relacional |
| Pagamentos | Mercado Pago (Pix com QR Code e webhook) | Exigido pelo enunciado; fica restrito ao Billing |
| Autenticação | JWT (JJWT, HMAC-SHA256) | Stateless: cada serviço valida o token sozinho, sem sessão compartilhada nem chamada a outro serviço |
| Entrada | Amazon API Gateway e AWS Lambda (Java 21, AWS SAM) | Ponto único de entrada; a autenticação por CPF roda sob demanda, sem manter um serviço ligado só para isso |
| Contêineres e orquestração | Docker (build multi-stage, `linux/amd64`) e Amazon EKS | O EKS gerencia o control plane do Kubernetes e se integra a VPC, IAM, ECR, RDS e Secrets Manager (RFC-0002); VMs sem orquestração e Kubernetes autogerenciado foram descartados por exigirem mais operação |
| Infraestrutura como código | Terraform (estado remoto em S3) e AWS SAM | Infraestrutura versionada e reproduzível, com `plan` revisado em pull request |
| CI/CD | GitHub Actions | Um pipeline por repositório: testes, cobertura e deploy no EKS |
| Testes | JUnit, Mockito, Testcontainers (PostgreSQL e LocalStack), Cucumber (BDD) e JaCoCo | Os testes de integração rodam contra PostgreSQL e SQS/SNS reais em contêiner; o build falha com cobertura abaixo de 80% |
| Observabilidade | New Relic (agente Java por auto-instrumentação) e logs JSON com `correlationId` | Reune métricas, traces e logs em uma ferramenta; Prometheus, Grafana e Loki autogerenciados foram descartados pelo custo de operação (ADR-0005) |
| Documentação da API | SpringDoc OpenAPI (Swagger UI) | Contrato da API gerado a partir do código, sem documento paralelo para manter |

## Trade-offs e evoluções

A divisão troca simplicidade por independência e resiliência. Estes são os custos aceitos, o que os reduz hoje e o que seria o próximo passo.

| Custo aceito | Como é reduzido hoje | Próximo passo |
| --- | --- | --- |
| Consistência eventual: a OS pode estar `CANCELADA` enquanto o Execution está `FALHOU` | Cada estado pertence a um domínio; o `correlationId` liga os eventos e a OS expõe o histórico da jornada | Se o número de participantes crescer, avaliar um orquestrador central |
| O fluxo fica espalhado entre serviços e é mais difícil de acompanhar | Contrato de eventos documentado, logs JSON com `correlationId` e rastreio no New Relic | Dashboards versionados como código (hoje são mantidos no produto) |
| Filas Standard entregam em duplicidade e fora de ordem | Outbox, consumidor idempotente por `eventId`, reentrega e DLQ de 14 dias de retenção para investigação e reprocessamento | Filas FIFO onde a ordem importar |
| O estorno é registrado no Billing e publicado como `PAGAMENTO_ESTORNADO`, sem chamada de devolução ao Mercado Pago | A compensação da saga fica completa dentro do sistema | Chamar a API de reembolso do Mercado Pago ao estornar |
| A Lambda de autenticação lê `os.usuario` direto no banco do OS Service, uma exceção à regra de banco isolado | Acesso restrito pelo Security Group do banco; a Lambda roda dentro da VPC | O OS Service expor a validação do cliente por API ou por evento |
| No AWS Academy não há IRSA: os pods usam as credenciais da role dos nós | Nenhuma chave de acesso fica dentro do pod; as credenciais vêm da role do nó | Uma role por serviço (IRSA) com permissões mínimas, fora do Learner Lab |

## Referências

| Componente | Repositório |
| --- | --- |
| Infraestrutura (EKS, mensageria, observabilidade) | [fiap-fase3-infraestrutura](https://github.com/rafaelllsilva/fiap-fase3-infraestrutura) |
| Banco de dados | [tech-challenge-infra-db](https://github.com/theodirk21/tech-challenge-infra-db) |
| OS Service | [tech-challenge-os-service](https://github.com/rafaelllsilva/tech-challenge-os-service) |
| Billing Service | [tech-challenge-billing-service](https://github.com/luisssato/tech-challenge-billing-service) |
| Execution Service | [tech-challenge-execution-service](https://github.com/theodirk21/tech-challenge-execution-service) |
| Serverless (Lambda e API Gateway) | [tech-challenge-serverless](https://github.com/luisssato/tech-challenge-serverless) |
