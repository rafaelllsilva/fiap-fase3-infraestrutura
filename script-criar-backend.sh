# /bin/sh

# 1. Cria o bucket de propósito geral
aws s3api create-bucket \
    --bucket archtechs-infra \
    --region us-east-1

# 2. Bloqueia todo o acesso público
aws s3api put-public-access-block \
    --bucket archtechs-infra \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 3. Força a criptografia padrão gerenciada pelo S3 (SSE-S3)
aws s3api put-bucket-encryption \
    --bucket archtechs-infra \
    --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'