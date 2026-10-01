output "server_ip" {
  value = multipass_instance.server.ipv4
}

output "worker_ips" {
  value = multipass_instance.worker[*].ipv4
}

output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "argocd_admin_password" {
  value     = data.kubernetes_secret_v1.argocd_admin_password.data["password"]
  sensitive = true
}

output "podinfo_url" {
  value = "http://${multipass_instance.worker[0].ipv4}:30080"
}
