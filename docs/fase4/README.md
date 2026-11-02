# Fase 4 — SAGA e observabilidade

**Diretriz de implementação — 28/10/2026.**

Usaremos SAGA coreografada com SQS, mantendo os contratos e o código atuais do execution-service. OS, billing e infraestrutura implementarão a integração descrita aqui.

- [Tarefas de OS e billing](alinhamento-os-billing.md): o que cada responsável deve implementar.
- [SAGA](saga.md): fluxo completo, eventos e status da OS.
- [Decisões de integração](decisoes-integracao.md): roteamento, aprovação, compensação e responsabilidades da infraestrutura.
- [Observabilidade](convencao-observabilidade.md): logs e New Relic.

Estas são as definições de trabalho para repassar ao grupo. A implementação e a validação ponta a ponta ainda precisam ser concluídas. A documentação não declara que OS, billing ou o roteamento já estejam prontos.
