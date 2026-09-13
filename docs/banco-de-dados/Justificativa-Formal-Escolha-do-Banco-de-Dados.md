# Justificativa Formal da Escolha do Banco de Dados

| Campo   | Valor                                                                                                                                                                                    |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Projeto | Tech Challenge — Sistema de Ordem de Serviço de Oficina Mecânica                                                                                                                         |
| Repositórios relacionados | [`tech-challenge-app`](https://github.com/Thiarges/tech-challenge-app) (aplicação) e [`tech-challenge-infra-db`](https://github.com/theodirk21/tech-challenge-infra-db) (infraestrutura) |
| Data    | 31-08-2026                                                                                                                                                                               |
| Autor   | Theo Dirk                                                                                                                                                                                |

## 1. Natureza do domínio

O domínio da aplicação é uma **oficina mecânica**, com entidades fortemente relacionadas entre si por múltiplas associações (cliente → ordem de serviço → veículo → serviços → peças). O modelo de dados exige:

- **Integridade referencial forte** (uma peça ou serviço não pode existir sem uma Ordem de Serviço válida; uma Ordem de Serviço não pode referenciar um cliente ou veículo inexistente).
- **Transações consistentes** ao criar uma Ordem de Serviço junto de suas peças e serviços associados.
- **Consultas relacionais** (ex.: listar todas as OS de um cliente, o histórico de peças usadas em uma OS, o tempo médio de execução de um tipo de serviço).
- **Catálogos normalizados** (`tipo_peca`, `tipo_servico`) reaproveitados por múltiplos registros, evitando duplicação de nome/valor.

Esse é um cenário clássico de **modelo relacional normalizado**, não de documentos semiestruturados ou dados chave-valor. Por isso, um banco **relacional (SQL)** é a escolha adequada, e não um banco NoSQL (documento, chave-valor ou wide-column).

## 2. Por que PostgreSQL

- Suporte maduro a `FOREIGN KEY`, `CHECK constraints`, tipos `DECIMAL`/`TIMESTAMP`, e `IDENTITY` para chaves primárias — todos usados diretamente no schema deste projeto (ver documento "Modelo Relacional e Diagrama ER").
- Compatibilidade nativa com o driver JPA/Hibernate utilizado pela aplicação (`spring-boot-starter-data-jpa` + Flyway).
- Suporte a schemas nomeados (usado aqui via schema `oficina`).
- Amplamente suportado como serviço gerenciado na AWS (Amazon RDS), permitindo backup automático, patch e storage encriptado sem esforço operacional adicional da equipe.

## 3. Por que Amazon RDS (gerenciado) em vez de Postgres em pod no EKS

Essa decisão está documentada em detalhe no **RFC-0001** (`Documentação de arquitetura de soluções/RFCs/RFC-0001-banco-de-dados.md`). Resumo:

| Critério | Postgres em pod no EKS | Amazon RDS PostgreSQL (escolhido) |
|---|---|---|
| Backup/patch automático | Não (manual) | Sim |
| Ciclo de vida independente do cluster | Não | Sim |
| Gestão de credenciais | Manual | AWS Secrets Manager |
| Esforço operacional | Alto | Baixo |
| Encriptação de storage | Configuração manual | Nativa (`storage_encrypted = true`) |

## Referências
- [`RFC-0001 (infraestrutura do banco)`](RFC-0001-banco-de-dados.md).
- [`Modelo Relacional Detalhado`](Modelo-Relacional-e-Diagrama-ER.md).
