# ADR-0002 — Escalonamento horizontal da aplicação de 2 a 10 réplicas via HPA

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceito e implementado                                |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `tech-challenge-app`                          |
| RFC relacionada | Nenhuma |

## Contexto

Uma única réplica do Deployment Spring Boot cria um ponto único de falha e impede manutenção (deploys, restarts) sem indisponibilidade. A carga de criação e consulta de ordens de serviço é variável ao longo do dia, e a aplicação é stateless após a autenticação por JWT, o que a torna candidata natural a escalonamento horizontal automático.

## Decisão

Manter duas réplicas iniciais do Deployment e configurar um `HorizontalPodAutoscaler` (HPA) que escala automaticamente entre 2 e 10 pods, disparando o scale-out quando a média de utilização de CPU atinge 70% ou a média de utilização de memória atinge 80%.

Para sustentar essa decisão sem sobrecarregar o banco de dados, foram aplicadas as seguintes medidas complementares:

- O pool de conexões Hikari é fixado em no máximo 3 conexões por pod, de modo que o pico de 10 pods não exceda a capacidade de conexões do RDS.
- Um `PodDisruptionBudget` (PDB) garante que ao menos um pod permaneça disponível durante interrupções.
- A estratégia de deploy é `RollingUpdate`, trocando no máximo um pod por vez para evitar indisponibilidade durante atualizações.

## Consequências

**Positivas:**
- Elimina o ponto único de falha ao manter no mínimo duas réplicas em operação normal.
- Absorve picos de carga de forma automática, sem intervenção manual, respeitando os limites de CPU/memória definidos.
- Permite deploys sem downtime graças ao RollingUpdate e ao PDB.

**Negativas / trade-offs aceitos:**
- O Metrics Server é uma dependência obrigatória: sem ele, o HPA não recebe métricas de CPU/memória e não escala.
- O limite de 3 conexões Hikari por pod é uma restrição deliberada que precisa ser revisitada caso o número máximo de réplicas do HPA seja aumentado no futuro, sob risco de esgotar as conexões disponíveis no RDS.

## Alternativas descartadas

- **Réplica única fixa**: descartada por gerar indisponibilidade em qualquer manutenção ou falha de pod.
- **Escalonamento manual (ajuste fixo do número de réplicas)**: descartado por não reagir a variações de carga em tempo real e exigir intervenção humana constante.
- **Escalonamento vertical (aumentar recursos do pod)**: descartado por ter limite físico do nó e não resolver o problema de ponto único de falha.

## Referências

- [`Diagrama de Componentes`](../c4/C4-Diagrama-de-Componentes.md) 
