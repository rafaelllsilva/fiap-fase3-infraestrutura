variable "cluster_name" {
  type        = string
  default     = "tech-challenge"
  description = "Nome do cluster Kind a ser criado."
}

variable "app_image" {
  type        = string
  default     = "tech-challenge-app:local"
  description = "Imagem Docker da aplicação (tag). Na CI é sobrescrita via TF_VAR_app_image com a tag do commit; localmente use a tag que você buildou e carregou no Kind."
}

variable "db_password" {
  type        = string
  sensitive   = true
  default     = "local-dev-postgres-password"
  description = "Senha do Postgres, injetada no Secret db-credentials. Valor de teste para o cluster efêmero; sobrescreva via TF_VAR_db_password se quiser."
}

variable "jwt_secret" {
  type        = string
  sensitive   = true
  default     = "local-dev-jwt-secret-min-32-characters-0001"
  description = "Chave HMAC de assinatura dos tokens JWT (mínimo 32 caracteres), injetada no Secret app-secrets. Valor de teste para o cluster efêmero; sobrescreva via TF_VAR_jwt_secret."
}
