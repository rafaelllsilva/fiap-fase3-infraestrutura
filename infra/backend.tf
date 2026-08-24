# Backend S3 com configuração parcial (nenhum valor hardcoded aqui de
# propósito — bucket/região/key variam por conta/ambiente e o projeto
# pode ser reusado por outros alunos). Os valores reais são passados em
# `terraform init -backend-config=backend.hcl` — ver infra/backend.hcl.example
# e a seção de bootstrap do bucket no CLAUDE.md. `use_lockfile = true`
# (dentro de backend.hcl) usa o locking nativo do S3, sem precisar de uma
# tabela DynamoDB separada.

resource "aws_s3_bucket" "fase3-backend" {
  bucket = var.project_name
}

terraform {
  backend "s3" {
    bucket       = "archtechs-infra"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
