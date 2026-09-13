# RFC-0001 — Banco de Dados da Aplicação (Tech Challenge)

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceito                                               |
| Autor       | Theo Dirk                                            |
| Data        | 31-08-2026                                        |
| Repositório afetado | `tech-challenge-infra-db`                     |

## Contexto

A aplicação principal do Tech Challenge (Fase 3) roda em um cluster **Amazon EKS** e precisa de um banco de dados relacional para persistência de dados. É necessário decidir onde e como esse banco será provisionado, operado e acessado pela aplicação.

## Problema

Precisamos de um banco de dados que seja:
- Confiável e gerenciável com o mínimo de esforço operacional.
- Seguro, com controle de acesso restrito à aplicação.
- Fácil de provisionar/destruir via IaC, já que a infraestrutura é derrubada após avaliação/gravação.
- Compatível com o restante do ecossistema (EKS, AWS, GitHub Actions).

## Alternativas consideradas

### 1. Banco rodando como Pod dentro do EKS (ex: Postgres via Deployment/StatefulSet)
- ✅ Não depende de serviço gerenciado, custo potencialmente menor.
- ❌ Sem gerenciamento automático de backup, patch e alta disponibilidade.
- ❌ Estado do banco fica acoplado ao ciclo de vida do cluster (risco de perda de dados).
- ❌ Exige PersistentVolume, gestão de storage, escalabilidade e segurança do próprio time.
- ❌ Mais esforço operacional para algo que não é o foco do desafio.

### 2. Amazon RDS PostgreSQL (gerenciado pela AWS) — **opção escolhida**
- ✅ Serviço totalmente gerenciado: backup automático, patching, storage encriptado.
- ✅ Isolado do ciclo de vida do cluster EKS — pode ser destruído/criado independentemente.
- ✅ Segurança de rede via Security Group dedicado, liberando acesso só para o SG do EKS na porta 5432.
- ✅ Credenciais geradas aleatoriamente e armazenadas no AWS Secrets Manager (sem hardcode).
- ✅ Provisionamento 100% via Terraform, com pipeline de CI/CD (GitHub Actions) rodando fmt/validate/plan/apply.
- ❌ Recurso "vive" fora do Kubernetes, exigindo um passo extra de integração (buscar host/porta/credenciais via Secrets Manager) para o app se conectar.
- ❌ Tem custo mesmo que dentro do free tier (`db.t3.micro`).

### 3. Outro serviço gerenciado (ex: Aurora Serverless, DynamoDB)
- ❌ Aurora Serverless: overhead de configuração maior, mais caro para o escopo do desafio.
- ❌ DynamoDB: não é solução relacional, exigiria modelagem NoSQL incompatível com o domínio atual da aplicação (que já é relacional).

## Decisão

Optamos pelo **Amazon RDS PostgreSQL**, provisionado via Terraform no repositório `tech-challenge-infra-db`, com:
- Geração de senha aleatória (`random_password`).
- Armazenamento de credenciais no AWS Secrets Manager.
- Subnet group dedicado em subnets privadas.
- Security Group liberando acesso apenas para o SG do EKS na porta 5432.
- Parameter group com ajustes de log (`log_statement`, `log_min_duration_statement`).

## Consequências

- O banco não roda como pod no EKS — não deve aparecer em `kubectl get pods`. Isso é esperado e correto.
- O app, para se conectar, precisa:
  1. Ler os outputs do Terraform (`db_endpoint`, `db_name`, etc.).
  2. Buscar usuário/senha no Secrets Manager (`secrets_manager_secret_arn`).
  3. Expor essas credenciais como `Secret` do Kubernetes para o Deployment do app.
- Qualquer mudança no Security Group do EKS (`eks_security_group_id`) exige reaplicar o Terraform deste repositório para manter o acesso liberado.
- A infraestrutura pode ser destruída com `terraform destroy` sem impactar o cluster EKS, já que são ciclos de vida independentes.

## Referências
- Repositório: [`tech-challenge-infra-db`](https://github.com/theodirk21/tech-challenge-infra-db) — `main.tf`, `variables.tf`, `outputs.tf`.
