# ADR-0004 — Controle da evolução do esquema de banco de dados com Flyway

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceito e implementado                                |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `tech-challenge-app`                          |
| RFC relacionada | RFC-0001 — Banco de Dados da Aplicação (Tech Challenge) |

## Contexto

O modelo relacional da aplicação evolui junto com o produto (novas colunas, novas tabelas, ajustes de constraints) e essa evolução precisa ser reproduzível e rastreável entre ambientes (desenvolvimento, homologação, produção), sem depender de alterações manuais no banco.

## Decisão

Versionar as migrations do schema PostgreSQL `oficina` como arquivos Flyway dentro do próprio repositório da aplicação (`tech-challenge-app`), aplicadas automaticamente no startup da aplicação. O Hibernate é configurado com `ddl-auto=validate`, ou seja, não realiza nenhuma alteração automática de schema, toda mudança estrutural passa obrigatoriamente por uma migration Flyway.

Regras adotadas:

- Migrations seguem a convenção de nomenclatura `VNNN__descricao.sql`.
- Migrations já aplicadas são consideradas imutáveis; qualquer ajuste subsequente deve ser feito em um novo arquivo de migration, nunca editando um arquivo já aplicado.

## Consequências

**Positivas:**
- Garante reprodutibilidade do schema entre ambientes, já que a mesma sequência de migrations é aplicada em qualquer ambiente novo.
- Evita divergências entre o schema esperado pelo Hibernate e o schema real do banco, pois `ddl-auto=validate` falha o startup caso haja incompatibilidade.
- Mantém histórico auditável de todas as alterações estruturais do banco, versionado junto com o código da aplicação.

**Negativas / trade-offs aceitos:**
- Exige disciplina da equipe para nunca editar uma migration já aplicada em algum ambiente, sob risco de causar divergência de checksum e falha na aplicação de migrations futuras.
- Adiciona uma etapa de execução das migrations no startup da aplicação, o que pode aumentar levemente o tempo de inicialização dos pods.
- Rollbacks de schema não são automáticos: reverter uma alteração estrutural exige escrever uma nova migration corretiva.

## Alternativas descartadas

- **`ddl-auto=update` do Hibernate**: descartado por gerar alterações de schema implícitas e não versionadas, dificultando auditoria e reprodutibilidade.
- **Alterações manuais de schema via scripts ad-hoc executados por operadores**: descartado por ser propenso a erro humano e por não deixar rastro versionado junto ao código.
- **Outra ferramenta de migration (ex.: Liquibase)**: descartada por preferência de integração mais direta com o ecossistema Spring Boot já em uso.

## Referências

- [`RFC-0001 — Banco de Dados da Aplicação (Tech Challenge)`](../rfc/RFC-0001-banco-de-dados.md)
