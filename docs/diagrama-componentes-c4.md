# Diagrama de Componentes — C4 Model (Nível 3)

Visão macro da infraestrutura do **Tech Challenge Fase 3**: a borda serverless que autentica
e roteia as chamadas, o cluster Kubernetes gerenciado onde a aplicação executa, e o banco
relacional gerenciado por trás dela.

Conforme orientado na live, este diagrama fica no **nível mais macro possível** e é voltado à
infraestrutura — os recursos que estão na nuvem AWS. Ficam deliberadamente de fora o
funcionamento interno da API (camadas, casos de uso, entidades) e as pipelines de CI/CD dos
quatro repositórios.

| | |
| --- | --- |
| Conta | AWS Academy Learner Lab |
| Região | `us-east-1` |
| VPC | `10.0.0.0/16` · 2 AZs |
| Cluster | `tech-challenge` · Kubernetes `1.36` |
| Node group | 3–4 × `t3.medium` (2 vCPU · 4 GiB) · desejado 3 |
| Namespace | `tech-challenge` |
| Banco de dados | Amazon RDS for PostgreSQL |
| Registro de imagens | ECR `tech-challenge-app` |

## Diagrama

```mermaid
flowchart TB
  classDef externo    fill:#E9ECF1,stroke:#5A6577,stroke-width:1.5px,color:#131A24
  classDef borda      fill:#FBF1E4,stroke:#A4611F,stroke-width:1.5px,color:#131A24
  classDef rede       fill:#E3F1EF,stroke:#1B6E68,stroke-width:1.5px,color:#131A24
  classDef k8s        fill:#E9EFF9,stroke:#2B5FA8,stroke-width:1.5px,color:#131A24
  classDef dados      fill:#F0EAF6,stroke:#6A4A85,stroke-width:1.5px,color:#131A24

  pessoa["<b>Consumidor da API</b><br/><i>Pessoa</i><br/>Abre e acompanha ordens de serviço"]
  postman["<b>Postman</b><br/><i>Sistema externo · cliente REST</i><br/>Dispara as requisições e guarda o JWT"]
  newrelic["<b>New Relic</b><br/><i>Sistema externo · observabilidade</i><br/>Recebe transações, traces e logs do agente APM"]

  subgraph aws["CONTA AWS — AWS Academy Learner Lab · us-east-1"]
    direction TB

    apigw["<b>Amazon API Gateway</b><br/><i>HTTP API · endpoint público</i><br/>Porta de entrada única de todos os endpoints"]
    lambda["<b>AWS Lambda — Authorizer</b><br/><i>Função serverless</i><br/>Autentica por CPF e emite o token JWT"]
    ecr["<b>Amazon ECR</b><br/><i>tech-challenge-app · scan on push</i><br/>Imagem Docker da API"]

    subgraph vpc["VPC — 10.0.0.0/16 · 2 AZs · subnets públicas e privadas"]
      direction TB

      nlb["<b>Network Load Balancer</b><br/><i>Service type=LoadBalancer</i><br/>Expõe a API para o API Gateway"]
      rota["<b>Roteamento de saída</b><br/><i>Internet Gateway + NAT Gateway</i><br/>Saída dos nós nas subnets privadas"]
      rds["<b>Amazon RDS for PostgreSQL</b><br/><i>Instância gerenciada · porta 5432 · DB subnet group</i><br/>Security group libera 5432 apenas para os nós do cluster"]

      subgraph eks["AMAZON EKS — cluster tech-challenge · Kubernetes 1.36"]
        direction TB

        cp["<b>Control plane gerenciado</b><br/><i>API server · etcd · scheduler</i>"]
        addons["<b>Add-ons do cluster</b><br/>vpc-cni · kube-proxy · coredns<br/>aws-ebs-csi-driver · metrics-server"]
        sc["<b>StorageClass gp3</b><br/><i>ebs.csi.aws.com · default</i><br/>Disponível para qualquer PersistentVolumeClaim"]

        subgraph ng["MANAGED NODE GROUP default — 3–4 × t3.medium · AL2023 · subnets privadas"]
          direction TB

          subgraph ns["NAMESPACE tech-challenge"]
            direction TB

            svcapi["<b>Service da API</b><br/><i>LoadBalancer → 8080</i>"]
            hpa["<b>HorizontalPodAutoscaler</b><br/><i>min 2 · max 10 · CPU e memória</i>"]
            pdb["<b>PodDisruptionBudget</b><br/><i>minAvailable: 1</i>"]
            app["<b>Deployment da API de Ordens de Serviço</b><br/><i>2 réplicas · imagem do ECR · probes</i><br/>Valida o JWT e executa as migrations Flyway<br/>Agente do New Relic embarcado na JVM"]
          end
        end
      end
    end
  end

  pessoa   -->|"usa"| postman
  postman  -->|"HTTPS · JSON"| apigw
  apigw    -->|"invoca o authorizer"| lambda
  apigw    -->|"requisição autorizada"| nlb
  nlb      -->|"TCP :80"| svcapi
  svcapi   -->|"balanceia entre as réplicas"| app
  hpa      -->|"escala 2 → 10"| app
  pdb      -->|"minAvailable: 1"| app
  app      -->|"JDBC :5432"| rds
  addons   -.->|"fornece métricas"| hpa
  ecr      -.->|"docker pull"| ng
  rota     -.->|"saída para internet"| ng
  app      -.->|"agente APM · traces e logs"| newrelic

  class pessoa,postman,newrelic externo
  class apigw,lambda borda
  class nlb,rota rede
  class cp,addons,svcapi,hpa,pdb,app k8s
  class ecr,sc,rds dados
```

### Legenda de cores

| Cor | Família | Exemplos |
| --- | --- | --- |
| Cinza-azulado | Externo — fora da conta AWS | Consumidor, Postman, New Relic |
| Ocre | Borda serverless gerenciada | API Gateway, Lambda Authorizer |
| Teal | Rede | VPC, NLB, Internet/NAT Gateway |
| Azul | Kubernetes | Control plane, add-ons, Deployment, HPA, PDB |
| Violeta | Dados e armazenamento | ECR, StorageClass, RDS PostgreSQL |

Linhas contínuas representam o caminho de uma requisição; linhas tracejadas representam
relações de suporte (provisionamento, telemetria, pull de imagem).

## Fluxo de uma requisição

1. **Postman → API Gateway.** A requisição HTTPS chega ao endpoint público do API Gateway,
   única porta de entrada da aplicação.
2. **API Gateway → Lambda Authorizer.** Nos endpoints protegidos, o gateway invoca a função
   Lambda, que autentica pelo CPF e emite o token JWT.
3. **API Gateway → Network Load Balancer.** Com a autorização concedida, a chamada é
   encaminhada ao balanceador criado pelo Service da aplicação.
4. **NLB → Service → Deployment.** O tráfego entra no cluster e é distribuído entre as
   réplicas da API, que validam o JWT recebido.
5. **Deployment → Amazon RDS.** A aplicação consulta e grava a ordem de serviço via JDBC na
   porta 5432. O security group do RDS só aceita conexões vindas dos nós do cluster.
6. **HPA → Deployment.** Em paralelo, o autoscaler lê as métricas do `metrics-server` e
   ajusta as réplicas entre 2 e 10; o PodDisruptionBudget mantém ao menos uma no ar.
7. **Agente → New Relic.** Durante todo o percurso, o agente embarcado na JVM envia a
   transação, seus traces e os logs correlacionados para o New Relic.

## Quem provisiona cada componente

A arquitetura é entregue por quatro repositórios independentes. O diagrama mostra o resultado
combinado; cada repositório é dono apenas da sua fatia.

| Componente | Repositório | Observação |
| --- | --- | --- |
| API Gateway | Autenticação | Pode ser criado junto da Lambda (SAM) ou no repositório de infraestrutura — decisão do time |
| Lambda Authorizer | Autenticação | Repositório próprio, com pipeline própria |
| VPC, NAT e Internet Gateway | Infraestrutura (este) | Módulo `terraform-aws-modules/vpc/aws` |
| Cluster EKS e add-ons | Infraestrutura (este) | Recursos nativos `aws_eks_cluster` e `aws_eks_addon` |
| Managed node group | Infraestrutura (este) | `aws_eks_node_group` com launch template próprio |
| Namespace e StorageClass | Infraestrutura (este) | Compartilhados; criados aqui para os outros dois repositórios não disputarem a posse |
| Amazon ECR | Infraestrutura (este) | O repositório é provisionado aqui; o build e o push da imagem são da pipeline da aplicação |
| Instância RDS PostgreSQL | Banco de dados | Consome a VPC, as subnets e o security group dos nós pelo state remoto |
| Deployment, Service, HPA e PDB | Aplicação | Inclui ConfigMap, Secret, as migrations Flyway e o agente do New Relic na imagem |

## Fora do escopo

- Funcionamento interno da API (camadas, casos de uso, entidades) — pertence a um diagrama
  de nível de código, não de infraestrutura.
- Pipelines de CI/CD dos quatro repositórios.
- Bucket S3 do state do Terraform: existe fora do ciclo de vida da aplicação e é criado
  manualmente (`script-criar-backend.sh`) antes de qualquer `apply`.
