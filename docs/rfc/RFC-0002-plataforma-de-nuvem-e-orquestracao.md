# RFC-0002 — Plataforma de Nuvem e Orquestração (Tech Challenge)

| Campo       | Valor                                              |
|-------------|-----------------------------------------------------|
| Status      | Aceita e implementada                                |
| Autor       | Hyun Min Cho                                         |
| Data        | 07-09-2026                                           |
| Repositório afetado | `fiap-fase3-infraestrutura`                   |

## Contexto

A solução do Tech Challenge (Fase 3) precisa de uma infraestrutura em nuvem capaz de rodar a aplicação em containers, escalar conforme a demanda e ser provisionada de forma reproduzível entre ambientes, sem depender de configuração manual de servidores.

## Problema

Precisamos de uma plataforma de nuvem e orquestração que seja:
- Capaz de rodar containers com escalonamento automático e alta disponibilidade.
- Integrada nativamente a um registro de imagens e a uma rede privada (VPC).
- Provisionável e reprodutível via Infraestrutura como Código (IaC).
- Compatível com o restante do ecossistema já adotado (banco gerenciado, pipelines de CI/CD).

## Alternativas consideradas

### 1. Execução local (sem nuvem)
- ✅ Sem custo de infraestrutura em nuvem.
- ❌ Não atende ao requisito de disponibilizar a aplicação de forma acessível e escalável para avaliação.
- ❌ Sem paridade com um ambiente de produção real.

### 2. Máquinas virtuais (VMs) sem orquestração
- ✅ Modelo simples e conhecido, baixo overhead conceitual.
- ❌ Escalonamento e recuperação de falhas precisariam ser implementados manualmente (scripts, load balancer configurado à mão).
- ❌ Sem padronização de deploy via manifestos declarativos.

### 3. Kubernetes autogerenciado (self-hosted, fora de um serviço gerenciado de nuvem)
- ✅ Controle total sobre a configuração do cluster.
- ❌ Exige operar o control plane (etcd, API server, upgrades de versão), o que é overhead desnecessário para o escopo do desafio.
- ❌ Maior superfície de responsabilidade operacional e de segurança para a equipe.

### 4. AWS com Amazon EKS e Amazon ECR — **opção escolhida**
- ✅ EKS gerencia o control plane do Kubernetes, reduzindo a operação a cargo da equipe.
- ✅ Integração nativa com VPC, IAM, ECR e demais serviços AWS já usados no projeto (RDS, Secrets Manager).
- ✅ Amazon ECR fornece registro de imagens Docker com varredura de vulnerabilidades no push.
- ✅ Terraform como IaC permite versionar e reproduzir toda a infraestrutura (VPC, subnets, EKS, ECR) entre ambientes.
- ❌ Exige credenciais e permissões AWS configuradas corretamente (IAM) para o provisionamento.
- ❌ Gera custo de recursos (nós do EKS, NAT Gateway, load balancer) mesmo em uso acadêmico.

## Decisão

Adotar a **AWS** como provedor de nuvem principal, com **Terraform** como ferramenta de Infraestrutura como Código, **Amazon EKS** para orquestração de containers e **Amazon ECR** como registro de imagens Docker da aplicação.

A infraestrutura de rede é composta por uma VPC com subnets públicas e privadas em duas Availability Zones, Internet Gateway e NAT Gateway, com os nós do EKS posicionados nas subnets privadas. O cluster `tech-challenge` roda com managed node group (mínimo 3, desejado 3, máximo 4 nós) e os addons `vpc-cni`, `kube-proxy`, `coredns`, EBS CSI Driver e Metrics Server.

## Consequências

- Toda a infraestrutura de nuvem passa a ser rastreável e reproduzível via Terraform, com o estado remoto armazenado em S3 com locking, evitando divergência entre ambientes ou aplicações concorrentes do Terraform.
- A equipe precisa manter credenciais AWS válidas e com permissões adequadas (IAM) para aplicar o Terraform.
- Os custos de infraestrutura (nós EKS, NAT Gateway, NLB) precisam ser monitorados, ainda que o ambiente seja acadêmico e possa ser destruído após a avaliação.
- Mudanças de infraestrutura passam a seguir o fluxo padrão de IaC (`terraform fmt`, `validate`, `plan`, `apply`), reduzindo o risco de alterações manuais não versionadas no console AWS.

## Referências

- Repositório: [`fiap-fase3-infraestrutura`](https://github.com/rafaelllsilva/fiap-fase3-infraestrutura).
