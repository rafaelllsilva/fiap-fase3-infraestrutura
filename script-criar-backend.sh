#!/bin/sh
# Garante que o bucket S3 do backend do state exista, com bloqueio de acesso
# público e criptografia. Idempotente: se o bucket já existe, não faz nada.
# Chamado manualmente (bootstrap local, primeira vez) e automaticamente pelas
# pipelines de CI antes de cada `terraform init`.
set -e

BUCKET="archtechs-infra"
REGION="us-east-1"

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Bucket $BUCKET já existe, nada a fazer."
  exit 0
fi

echo "Bucket $BUCKET não existe, criando..."

# 1. Cria o bucket de propósito geral
aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION"

# 2. Bloqueia todo o acesso público
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 3. Força a criptografia padrão gerenciada pelo S3 (SSE-S3)
aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
