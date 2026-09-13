# RFC-0004 — Autenticação Stateless Baseada em JWT

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Parcialmente implementada                            |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `tech-challenge-app` (API) e `tech-challenge-serverless` (Lambda/API Gateway) |

## Contexto

Os endpoints sensíveis da aplicação (por exemplo, abertura de ordens de serviço) precisam ser protegidos por autenticação e autorização por papel. Além disso, a aplicação roda com múltiplas réplicas escaláveis horizontalmente, o que exige um mecanismo de autenticação que não dependa de sessão compartilhada entre pods.

## Problema

Precisamos de um mecanismo de autenticação que seja:
- Stateless, permitindo que qualquer pod valide a requisição sem consultar um estado de sessão centralizado.
- Capaz de carregar informação de papel/permissão (`CLIENTE`, `MECANICO`, `ATENDENTE`, `GERENTE`) para autorização por rota.
- Aderente ao requisito da fase de que a emissão do token ocorra via uma **AWS Lambda** acionada por um **Amazon API Gateway**, autenticando o usuário por CPF.

## Alternativas consideradas

### 1. Sessão de servidor (session cookie + armazenamento centralizado)
- ✅ Modelo simples e amplamente conhecido.
- ❌ Exige armazenamento de sessão compartilhado entre pods (ex.: Redis), adicionando um componente de infraestrutura extra.
- ❌ Não é stateless, o que contraria o objetivo de escalabilidade horizontal simples da aplicação.

### 2. Tokens opacos validados contra um serviço central
- ✅ Permite revogação imediata de tokens.
- ❌ Cada requisição exigiria uma chamada adicional a um serviço de validação, aumentando latência e acoplamento.
- ❌ Ainda assim não elimina a necessidade de um componente central com estado.

### 3. Autenticação sem API Gateway dedicado (login direto na API Spring Boot) — **situação atual**
- ✅ Mais simples de implementar no curto prazo, sem depender de infraestrutura adicional (API Gateway/Lambda).
- ❌ Não atende ao requisito explícito da fase de que todos os endpoints passem pelo API Gateway e que a emissão do JWT ocorra em uma Lambda dedicada.

### 4. JWT assinado por HMAC-SHA256, emitido por uma Lambda atrás do API Gateway, autenticado por CPF — **arquitetura-alvo**
- ✅ Elimina estado de sessão nos pods: qualquer pod valida o JWT localmente a partir da assinatura.
- ✅ Papéis embutidos no token (`role`) permitem aplicar regras de autorização por rota na API.
- ✅ Atende ao requisito da fase de centralizar a autenticação em uma Lambda acionada pelo API Gateway.
- ❌ Requer implementação e publicação de uma Lambda dedicada (ainda ausente nos repositórios atuais) e configuração do API Gateway como proxy para o NLB da aplicação.
- ❌ A chave de assinatura HMAC precisa de rotação e armazenamento seguro (nunca em código ou documentação).

## Decisão

Adotar **JWT assinado por HMAC-SHA256**, com expiração configurável e autorização por role, como mecanismo de autenticação da aplicação. Para aderência completa ao requisito da fase, a emissão do token deve ser transferida para uma **AWS Lambda** acionada por um **Amazon API Gateway**, autenticando o usuário por CPF.

## Consequências

- A chave de assinatura (`JWT_SECRET`) exige rotação periódica e deve ser armazenada como secret, nunca versionada em código ou documentação.
- Rotas de login e endpoints do Actuator/Swagger permanecem públicos; os demais acessos são controlados por role (`CLIENTE`, `MECANICO`, `ATENDENTE`, `GERENTE`).
- Migrar a emissão do JWT para a Lambda exigirá criar e publicar a função (possivelmente em um quarto repositório) e configurar no API Gateway a rota de autenticação e o proxy para o NLB da aplicação.

## Referências

- Repositórios: [`tech-challenge-app`](https://github.com/Thiarges/tech-challenge-app) (API) e [`tech-challenge-serverless`](https://github.com/luisssato/tech-challenge-serverless) (Lambda/API Gateway) .
