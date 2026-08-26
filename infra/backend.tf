# Backend S3 do state, criado manualmente pelo script script-criar-backend.sh
terraform {
  backend "s3" {
    bucket       = "archtechs-infra"
    key          = "infra-cluster/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
