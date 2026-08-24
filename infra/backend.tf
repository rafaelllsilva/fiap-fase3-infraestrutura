# Backend S3 do state. O bucket NÃO é criado por este Terraform (problema de
# ovo-e-galinha: ele precisa existir antes do `init`) — é criado uma única vez
# à mão, ver a seção de bootstrap do bucket no CLAUDE.md. `use_lockfile = true`
# usa o locking nativo do S3, sem precisar de uma tabela DynamoDB separada.

terraform {
  backend "s3" {
    bucket       = "archtechs-infra"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
