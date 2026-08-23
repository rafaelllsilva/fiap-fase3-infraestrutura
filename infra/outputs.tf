output "cluster_name" {
  value       = kind_cluster.this.name
  description = "Nome do cluster Kind criado."
}

output "cluster_endpoint" {
  value       = kind_cluster.this.endpoint
  description = "Endpoint da API do cluster."
}

output "kubeconfig_path" {
  value       = kind_cluster.this.kubeconfig_path
  description = "Caminho do kubeconfig gerado para acessar o cluster."
}
