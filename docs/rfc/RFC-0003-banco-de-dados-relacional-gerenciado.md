# RFC-0003 — Banco de Dados Relacional Gerenciado para o Domínio da Oficina

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceita e implementada                                |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `tech-challenge-infra-db`                     |

## Contexto

O domínio da oficina mecânica manipula clientes, veículos, ordens de serviço, catálogos de peças e serviços, usuários e histórico de transições de status, com relações e integridade referencial entre essas entidades (por exemplo, uma ordem de serviço referencia um cliente e um veículo existentes). Esta RFC complementa a [`RFC-0001 — Banco de Dados da Aplicação`](RFC-0001-banco-de-dados.md), registrando especificamente a justificativa da escolha de um banco **relacional** para esse domínio, em contraste com alternativas não relacionais.

## Problema

Precisamos de um banco de dados que seja:
- Capaz de expressar e impor relações entre entidades (chaves estrangeiras, constraints de unicidade).
- Transacional, garantindo consistência quando uma operação envolve múltiplas tabelas (ex.: criar uma OS e seus itens de peça/serviço).
- Compatível com SQL, já que o domínio é naturalmente tabular e relacional.
- Operável com o mínimo de esforço de manutenção (backup, patch, storage), dado o escopo do desafio.

## Alternativas consideradas

### 1. PostgreSQL em StatefulSet no EKS (autogerenciado)
- ✅ Não depende de um serviço gerenciado adicional.
- ❌ Acopla o estado do banco ao ciclo de vida do cluster Kubernetes.
- ❌ Não atende ao requisito de "banco de dados gerenciado" exigido pela fase.

### 2. Banco de dados NoSQL (ex.: DynamoDB)
- ✅ Escalabilidade horizontal nativa e baixa latência para acessos por chave.
- ❌ O domínio é essencialmente relacional (cliente–veículo–OS–peças–serviços–histórico), o que exigiria modelagem desnormalizada e duplicação de dados incompatível com as regras de integridade necessárias.
- ❌ Sem suporte nativo a transações multi-tabela nem a chaves estrangeiras.

### 3. Banco instalado manualmente em uma VM (EC2)
- ✅ Controle total sobre configuração do servidor de banco.
- ❌ Backup, patch, storage e alta disponibilidade passam a ser responsabilidade manual da equipe, causando considerável overhead operacional.
- ❌ Sem integração nativa com Secrets Manager ou com o Security Group do EKS por padrão.

### 4. Amazon RDS PostgreSQL 16 em subnets privadas — **opção escolhida**
- ✅ PostgreSQL oferece transações ACID, chaves estrangeiras, constraints de unicidade e SQL completo para o domínio relacional da oficina.
- ✅ RDS reduz a responsabilidade operacional de backup, storage e manutenção do servidor de banco.
- ✅ Acesso restrito à rede privada da VPC, sem exposição pública.
- ❌ Exige que a aplicação limite o pool de conexões para não esgotar as conexões disponíveis do RDS conforme o HPA escala os pods.

## Decisão

Adotar o **Amazon RDS PostgreSQL 16**, em subnets privadas, como banco de dados relacional da aplicação, reafirmando e detalhando — sob a ótica do domínio de dados da oficina — a decisão já registrada na [`RFC-0001`](RFC-0001-banco-de-dados.md) e formalizada na [`ADR-0001`](../adr/ADR-0001-banco-de-dados-gerenciado.md).

Como consequência direta do domínio relacional, o projeto fixa o pool de conexões Hikari em no máximo 3 conexões por pod, garantindo que o HPA de até 10 pods não sature as conexões disponíveis no RDS.

## Consequências

- O acesso ao banco ocorre exclusivamente pela rede privada da VPC, nunca pela internet pública.
- A aplicação deve tratar o limite de conexões por pod (Hikari = 3) como uma restrição de arquitetura, revisitando-a caso o limite máximo de réplicas do HPA seja alterado.
- A escolha de um banco relacional impõe que qualquer evolução do domínio (novas entidades, novos relacionamentos) seja modelada via migrations versionadas (ver decisão de uso do Flyway).

## Referências

- Repositório: [`tech-challenge-infra-db`](https://github.com/theodirk21/tech-challenge-infra-db)
- [`RFC-0001 — Banco de Dados da Aplicação (Tech Challenge)`](RFC-0001-banco-de-dados.md)
