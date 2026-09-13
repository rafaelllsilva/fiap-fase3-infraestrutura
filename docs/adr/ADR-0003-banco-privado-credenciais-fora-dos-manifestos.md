# ADR-0003 — Banco de dados privado e credenciais fora dos manifestos versionados

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceito e implementado                                |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `tech-challenge-infra-db` e `fiap-fase3-infraestrutura` |
| RFC relacionada | RFC-0001 — Banco de Dados da Aplicação (Tech Challenge) |

## Contexto

Credenciais ou endpoints de banco de dados presentes em manifests versionados (Kubernetes YAML, repositório de código) representam um risco relevante de vazamento, já que qualquer pessoa com acesso ao repositório teria acesso ao banco. Além disso, a API da aplicação não tem necessidade de expor o RDS publicamente, pois todo o tráfego de banco se origina de dentro da VPC, a partir dos pods no EKS.

## Decisão

Não expor o Amazon RDS publicamente e restringir o acesso de rede exclusivamente ao necessário:

- O RDS é provisionado com `publicly_accessible = false`, em subnets privadas.
- O Security Group do RDS libera a porta TCP/5432 somente a partir do Security Group do cluster EKS informado via Terraform.
- As credenciais do banco (usuário e senha) são geradas aleatoriamente pelo Terraform e armazenadas no AWS Secrets Manager, nunca em texto plano em código ou manifests.
- A pipeline de deploy lê as credenciais do Secrets Manager e as injeta no Kubernetes Secret `app-secrets` no momento do deploy, a partir do qual a aplicação lê `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME` e `SPRING_DATASOURCE_PASSWORD`.

## Consequências

**Positivas:**
- Elimina a superfície de ataque de um banco publicamente acessível na internet.
- Remove qualquer credencial de banco do histórico de commits e de manifests versionados.
- Centraliza a rotação e o gerenciamento de credenciais no AWS Secrets Manager.

**Negativas / trade-offs aceitos:**
- O runner da pipeline e qualquer processo que precise acessar o banco diretamente (ex.: para debug) precisa de conectividade com a VPC e autorização explícita, o que aumenta a fricção operacional em comparação a um banco publicamente acessível.
- Qualquer alteração no Security Group do EKS (ex.: recriação do cluster) exige reaplicar o Terraform do repositório `tech-challenge-infra-db` para manter a regra de acesso válida.
- A aplicação passa a depender de um passo de injeção de secrets na pipeline; falhas nesse passo impedem o deploy de subir com as credenciais corretas.

## Alternativas descartadas

- **RDS publicamente acessível**: descartado por expor desnecessariamente o banco à internet, ampliando a superfície de ataque.
- **Credenciais fixas em ConfigMap ou hardcoded no código**: descartado por representar exposição direta de segredos em texto plano e versionado.
- **Gerenciamento manual de credenciais fora do Secrets Manager**: descartado por não oferecer rotação, auditoria nem integração nativa com a pipeline de deploy.

## Referências

- [`RFC-0001 — Banco de Dados da Aplicação (Tech Challenge)`](../rfc/RFC-0001-banco-de-dados.md)
