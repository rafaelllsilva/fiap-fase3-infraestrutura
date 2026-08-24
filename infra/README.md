# Terraform - Amazon EKS Cluster Infrastructure

Este projeto provisiona uma infraestrutura Kubernetes na AWS (EKS - Amazon Elastic Kubernetes Service) seguindo as melhores práticas de segurança e escalabilidade.

## 🎯 Visão Geral

A infraestrutura provisionada inclui:

- **VPC** com subnets públicas e privadas, Nat Gateway e Internet Gateway
- **Cluster Amazon EKS** com configuração segura de endpoints (público e privado)
- **Managed Node Groups** com Auto Scaling para os nós do cluster (instâncias t3.micro)
- **IAM Roles** para os Worker Nodes e suporte a IRSA (IAM Roles for Service Accounts)
- **Load Balancer** para exposição do cluster
- **Recursos Kubernetes**: Namespace, ConfigMaps, Secrets, StatefulSets, Deployments, HPA, NetworkPolicies

## 📁 Estrutura do Projeto

```
infra/
├── main.tf                 # Recursos principais e deploy dos manifests
├── providers.tf           # Configuração dos providers (AWS e Kubernetes)
├── variables.tf           # Variáveis de configuração
├── outputs.tf            # Outputs para consumo
├── README.md             # Documentação deste arquivo
└── terraform.tfstate     # Estado do Terraform (gerado)
```

## 🚀 Como Usar

### 1. Preparação do Ambiente

Certifique-se de ter instalado:

- **Terraform** >= 1.5.0
- **kubectl** >= 1.20
- **AWS CLI** >= 2.x
- **Docker** (opcional, para imagens Docker)

Configure suas credenciais AWS:

```bash
aws configure
```

Certifique-se de que sua conta tem permissões para:
- `AmazonEKS`, `AmazonEKSWorker`, `AmazonECSAgent`
- `AWS::AccessAnalyzer`
- `autoscaling::*`
- `ec2:*` (limitado)
- `elasticloadbalancing:*`
- `eks:*`
- `iam:*`
- `kms:*`
- `logs:*`
- `ram:*`
- `rds:*`
- `resource-groups:*`
- `s3:*`
- `secretsmanager:*`
- `servicecatalog:*`
- `sts:*`
- `support:*`

### 2. Configure as Variáveis

Edite o arquivo `variables.tf` ou defina variáveis via Terraform:

```bash
terraform init
terraform validate
```

Variáveis obrigatórias:

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `aws_region` | `us-east-1` | Região da AWS |
| `cluster_name` | `tech-challenge-eks` | Nome do cluster EKS |
| `environment` | `dev` | Ambiente (dev, staging, prod) |
| `aws_access_key_id` | `null` | Access Key AWS (use EC2 Role em produção) |
| `aws_secret_access_key` | `null` | Secret Key AWS (use EC2 Role em produção) |

Variáveis sensíveis (definir em arquivo `.tfvars` ou via CLI):

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `db_password` | `local-dev-postgres-password` | Senha do Postgres |
| `jwt_secret` | `local-dev-jwt-secret-min-32-characters-0001` | Chave JWT |

Para uso em produção, sobrescreva estas variáveis com valores mais seguros.

### 3. Inicialize o Backend do Terraform

```bash
terraform init
```

Para CI/CD (GitHub Actions), configure o backend remoto no `main.tf`:

```hcl
terraform {
  backend "s3" {
    bucket  = "your-terraform-state-bucket"
    key     = "eks/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
```

### 4. Aplique a Infraestrutura

```bash
terraform apply
```

A infraestrutura será criada na seguinte ordem:

1. **VPC** com subnets públicas e privadas
2. **IAM Role** para Worker Nodes
3. **OIDC Provider** para IRSA
4. **Cluster EKS** com configuração segura
5. **Managed Node Groups** (Auto Scaling para nós EC2)
6. **IAM Policies** para o cluster e RBAC
7. **Recursos Kubernetes** (namespace, configmaps, secrets, deployments, etc.)

O tempo total para deployment pode variar entre 5-15 minutos dependendo da região AWS.

### 5. Atualize o Kubeconfig

Após o deploy, atualize o kubeconfig local para se conectar ao cluster:

```bash
aws eks update-kubeconfig --region us-east-1 --name tech-challenge-eks
```

Ou via script:

```bash
terraform output kubeconfig_update_command
# Copie o comando acima e execute em seu terminal local
```

### 6. Verifique o Cluster

```bash
kubectl cluster-info
kubectl get nodes
kubectl get namespaces
kubectl get configmaps -A
kubectl get secrets -A
kubectl get pods -A
```

### 7. Limpeza (Destruição)

```bash
terraform destroy
```

## 🔧 Arquitetura de Rede

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS VPC                                  │
│  ┌─────────────────┐         ┌─────────────────┐           │
│  │  Public Subnets │         │  Private Subnets │           │
│  │  - 10.0.1.0/24  │         │  - 10.0.10.0/24 │            │
│  │  - 10.0.2.0/24  │         │  - 10.0.11.0/24 │            │
│  │  └──────┬──────┘         │         └───────┘            │
│  │         │                │                               │
│  │     ┌───┘                │                                │
│  │     │                   │                                │
│  │  ┌───┴───┐             │                                │
│  │  │IGW----┤ Nat GW      │                                │
│  │  └────┬──┘             │                                │
│  └───────┼───────────────┘                                │
│          │                                                │
│  ┌───────┴───────┐       ┌─────────────────────────────┐   │
│  │     ALB       │──────│      EKS Cluster            │   │
│  │     └───┬───┘     │   │  (kubernetes.io/cluster/)    │   │
│  │         │        │   │  - Private Subnets          │   │
│  │         │        │   │  - Cluster SG              │   │
│  │         │        │   │  - Endpoints (priv/pub)    │   │
│  │  ┌──────┴────┐   │   └─────────────────────────────┘   │
│  │  │   EKS     │   │                                     │
│  │  │ Worker 1  │   │                                     │
│  │  │ Worker 2  │   │                                     │
│  │  │ Worker 3  │   │                                     │
│  │  └──────────┘   │                                     │
│  │                │                                     │
│  └────────────────┘                                     │
└─────────────────────────────────────────────────────────────┘
```

## 🔐 Segurança

### Autenticação no EKS

O cluster EKS usa a autenticação via AWS IAM:

```
Usuário Local → AWS IAM → EKS Cluster API
```

### Permissões IAM dos Worker Nodes

Cada worker node assume a role:
- `AmazonEKSWorkerPolicy` - Permite acesso ao cluster EKS
- `AmazonEKSManagedClusterPolicy` - Permite acessar clusters gerenciados
- `AmazonEC2ContainerRegistryReadOnly` - Pull de imagens do ECR

### IRSA (IAM Roles for Service Accounts)

O cluster tem um OIDC Provider configurado que permite:

```
Pod ServiceAccount → OIDC Token → IAM Role AWS → AWS Resource
```

Isso permite que pods acessem serviços AWS sem credentials hardcoded.

### Privacidade dos Endpoints

- **Endpoint Público**: API Server acessível de fora do VPC (composto por ALB público)
- **Endpoint Privado**: API Server acessível apenas dentro do VPC (API de pods, comunicação entre nós)

### Network Policies

As NetworkPolicies restringem o tráfego entre pods e serviços:

- **Default Deny Ingress/Egress**: Nenhuma política de rede por padrão
- **Allow List**: Somente tráfego de namespaces e pods específicos

## 📦 Recursos Kubernetes Provisionados

| Recurso | Nome | Namespace | Descrição |
|---------|------|----------|-----------|
| Namespace | `tech-challenge` | Default | Namespace principal do projeto |
| ConfigMap | `tech-challenge-config` | tech-challenge | Configurações da aplicação |
| Secret | `tech-challenge-secret` | tech-challenge | Senhas e secrets da aplicação |
| StatefulSet | `postgres-tech-challenge-db` | tech-challenge | PostgreSQL em volume effacement |
| Deployment | `tech-challenge-app` | tech-challenge | Aplicação principal |
| HorizontalPodAutoscaler | `tech-challenge-app-hpa` | tech-challenge | Auto-scaling baseado em CPU/Memory |
| Service | `tech-challenge-service` | tech-challenge | Service do tipo ClusterIP/LoadBalancer |
| Ingress | `tech-challenge-ingress` | tech-challenge | Ingress para roteamento de tráfego |
| NetworkPolicy | `tech-challenge-app-network-policy` | tech-challenge | Políticas de rede para pods |
| NetworkPolicy | `tech-challenge-db-network-policy` | tech-challenge | Políticas de rede para banco |

## 🐳 Imagem da Aplicação

Para subir sua aplicação:

```bash
docker build -t tech-challenge-app:local .
docker push tech-challenge-app:local
```

A aplicação é carregada no cluster via `kind load docker-image`.

## 📊 Monitoramento

O cluster é configurado com Prometheus e Grafana para monitoramento:

- **Prometheus**: Coleta métricas dos pods e do cluster
- **Grafana**: Dashboard para visualização das métricas

Para acessar, use o endpoint do Grafana configurado no namespace.

## 🚧 CI/CD Pipeline (Exemplo)

```yaml
# .github/workflows/deploy.yml
name: Deploy to EKS

on:
  push:
    branches: [main, develop]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3

      - name: Configure AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          version: 1.5.0

      - name: Initialize Terraform
        run: terraform init

      - name: Set Terraform Variables
        env:
          DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
          JWT_SECRET: ${{ secrets.JWT_SECRET }}
          APP_IMAGE: ${{ secrets.APP_IMAGE }}
        run: |
          export ${{ secrets.DB_PASSWORD }}
          export ${{ secrets.JWT_SECRET }}
          export ${{ secrets.APP_IMAGE }}
          terraform apply -auto-approve

      - name: Cleanup
        if: always()
        run: terraform destroy -auto-approve
```

## 🔍 Debug e Troubleshooting

### Verificar status do cluster

```bash
aws eks describe-cluster --name tech-challenge-eks --region us-east-1
```

### Verificar nós do cluster

```bash
kubectl get nodes --output wide
kubectl describe nodes
```

### Verificar logs dos pods

```bash
kubectl get pods -A
kubectl logs -l app=tech-challenge-app -n tech-challenge
```

### Verificar permissões IAM

```bash
aws iam list-attached-role-policies --role-name tech-challenge-eks-node-role
aws iam list-role-policy-attachments --role-name tech-challenge-eks-node-role
```

### Verificar VPC e Subnets

```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${cluster_name}-vpc" --region us-east-1
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxxxxxxxx" --region us-east-1
```

## 📝 Notas Importantes

1. **Multi-AZ**: Se estiver usando múltiplas Availability Zones, certifique-se de configurar subnets em pelo menos 2 AZs.

2. **Node Groups**: Para produção, aumente o número de node groups e o `min_size` para ter alta disponibilidade.

3. **Security Groups**: Os Security Groups são configurados para permitir apenas o tráfego necessário do cluster e dos pods.

4. **Criptografia**: Os recursos do EKS são criptografados em repouso (se suportado pela região).

5. **Tags**: Todos os recursos têm tags padrão para fácil gerenciamento e faturamento:
   - `Environment`
   - `ManagedBy`
   - `Project`

## 📚 Recursos Adicionais

- **terraform-aws-modules/eks**: Módulo usado para criar EKS
- **terraform-aws-modules/vpc**: Módulo usado para criar VPC
- **HashiCorp Terraform**: Documentação oficial: https://www.terraform.io/docs/providers/aws

## 📄 Licença

Copyright © 2026 - Todos os direitos reservados.