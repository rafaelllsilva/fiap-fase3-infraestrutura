# Fase 4 — SAGA e observabilidade

**Proposta para discussão do grupo — 27/10/2026.**

O objetivo é combinar como os três serviços vão trocar eventos e como acompanhar uma OS pelos logs.

- [SAGA](saga.md): fluxo principal e compensações.
- [Observabilidade](convencao-observabilidade.md): padrão básico de logs e ajustes no New Relic.
- [Decisões pendentes](decisoes-pendentes.md): cinco pontos para alinharmos antes da integração.

O execution já possui mensageria e logs JSON. Na versão revisada, OS tem apenas o README e billing ainda não foi disponibilizado. Por isso, os fluxos entre os três serviços abaixo são propostas, não uma integração já validada.

Cada responsável implementa a SAGA no seu serviço. A frente de documentação e observabilidade mantém este material, ajusta o New Relic e ajuda a demonstrar o fluxo completo.
