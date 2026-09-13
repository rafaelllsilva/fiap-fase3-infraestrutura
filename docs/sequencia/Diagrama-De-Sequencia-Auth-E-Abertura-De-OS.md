# Diagrama de Sequênica - Fluxos de autenticação e abertura de ordem de serviço

O diagrama a seguir mostra o fluxo requerido, incluindo a arquitetura-alvo de API Gateway/Lambda. Os passos marcados como **alvo** dependem dos componentes ainda ausentes; os demais representam o comportamento existente no código.

```mermaid
sequenceDiagram
    autonumber
    actor U as Usuário
    participant G as API Gateway (alvo)
    participant L as Lambda Auth (alvo)
    participant N as NLB
    participant A as API Spring Boot no EKS
    participant D as RDS PostgreSQL

    U->>G: POST /auth com CPF e credencial
    G->>L: Invoca rota de autenticação
    L->>D: Consulta usuário/cliente por CPF
    D-->>L: Usuário, senha_hash e role
    L->>L: Valida credencial e assina JWT HS256
    L-->>G: accessToken, role e expiração
    G-->>U: 200 JWT

    U->>G: POST /api/ordemDeServico\nAuthorization: Bearer JWT
    G->>N: Encaminha rota protegida
    N->>A: HTTP para pod saudável
    A->>A: Filtro JWT valida assinatura e expiração
    A->>D: Insere ordem_de_servico
    opt Peças ou serviços informados
        A->>D: Insere peca e/ou servico
    end
    A->>D: Registra status inicial no histórico
    D-->>A: OS persistida
    A-->>N: 201 Created + representação da OS
    N-->>G: Resposta HTTP
    G-->>U: 201 Created
```