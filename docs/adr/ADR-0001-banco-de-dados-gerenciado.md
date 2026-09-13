# ADR-0001 — Uso de Banco de Dados Gerenciado (Amazon RDS) em vez de Postgres autogerenciado no EKS

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceito                                               |
| Autor       | Theo Dirk                                            |
| Data        | 31-08-2026                                        |
| Repositório afetado | `tech-challenge-infra-db`                     |
| RFC relacionada | RFC-0001 — Banco de Dados da Aplicação (Tech Challenge) |

## Contexto

A Fase 3 do Tech Challenge exige explicitamente um **"Banco de Dados Gerenciado (PostgreSQL, MySQL, SQL Server, etc.)"** como parte da infraestrutura obrigatória. Nas fases anteriores do projeto (`tech-challenge-fase-1`), o Postgres rodava como um `StatefulSet` dentro do próprio cluster Kubernetes — uma solução autogerenciada, válida naquele contexto, mas que não atende ao requisito de "gerenciado" desta fase.

A discussão das alternativas consideradas (Postgres em pod no EKS, Amazon RDS, outros serviços gerenciados como Aurora Serverless ou DynamoDB) está detalhada na RFC-0001. Este ADR registra a decisão final e permanente resultante dessa discussão.

## Decisão

Adotar o **Amazon RDS para PostgreSQL** como banco de dados da aplicação, provisionado via Terraform no repositório `tech-challenge-infra-db`, com as seguintes características fixas:

- Instância RDS PostgreSQL (major version `16`, minor version resolvida automaticamente pela AWS).
- Senha gerada aleatoriamente (`random_password`) e armazenada no AWS Secrets Manager — nenhuma credencial em texto plano no código ou em manifests.
- Rede isolada: `DB Subnet Group` em subnets privadas, `publicly_accessible = false`.
- `Security Group` dedicado, liberando acesso à porta 5432 exclusivamente para o Security Group do cluster EKS.
- `Parameter Group` próprio, com log de queries habilitado (`log_statement`, `log_min_duration_statement`) para observabilidade.
- Ciclo de vida independente do cluster EKS: o banco pode ser criado e destruído (`terraform apply` / `terraform destroy`) sem afetar o cluster, e vice-versa.

O Postgres **não roda mais como pod dentro do Kubernetes** a partir desta decisão — o antigo `k8s/postgres.yaml` do repositório da aplicação deixa de ser utilizado.

## Consequências

**Positivas:**
- Atende literalmente o requisito obrigatório de "banco de dados gerenciado" do edital.
- Backup automático, patching e storage encriptado passam a ser responsabilidade da AWS, não da equipe.
- Rotação de credenciais centralizada no Secrets Manager, sem necessidade de gerenciar Secrets do Kubernetes manualmente.
- Infraestrutura do banco pode ser destruída após a gravação do vídeo de demonstração sem impactar os demais componentes.

**Negativas / trade-offs aceitos:**
- Introduz uma dependência de rede entre o cluster EKS e um recurso externo a ele — qualquer mudança no Security Group do EKS exige reaplicar o Terraform deste repositório.
- Gera custo mesmo dentro do free tier (`db.t3.micro`), diferente de um Postgres em pod, que "aparenta" não ter custo direto (embora consuma recursos do próprio cluster).
- Exige um passo adicional de integração: a aplicação precisa buscar host, porta e credenciais via Terraform outputs / AWS Secrets Manager, em vez de resolver um serviço interno do Kubernetes por nome (`postgres-service`).

## Alternativas descartadas

Ver RFC-0001 para a análise completa. Resumo:
- **Postgres em pod no EKS**: descartado por não atender ao requisito de "gerenciado" e por acoplar o estado do banco ao ciclo de vida do cluster.
- **Aurora Serverless**: descartado por overhead de configuração maior que o necessário para o escopo do desafio.
- **DynamoDB**: descartado por incompatibilidade com o domínio relacional da aplicação (ver "Justificativa Formal da Escolha do Banco de Dados").

## Referências

- [`RFC-0001 — Banco de Dados da Aplicação (Tech Challenge)`](RFC-0001-banco-de-dados.md)
- [`Justificativa Formal da Escolha do Banco de Dados`](Justificativa-Formal-Escolha-do-Banco-de-Dados.md)
- [`Modelo Relacional e Diagrama ER`](Modelo-Relacional-e-Diagrama-ER.md)
- Repositório: [`tech-challenge-infra-db`](https://github.com/theodirk21/tech-challenge-infra-db) — `main.tf`, `variables.tf`, `outputs.tf`
