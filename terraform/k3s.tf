data "external" "k3s_token" {
  program = ["${path.module}/scripts/k3s-wait-and-fetch-token.sh"]
  query = {
    name = multipass_instance.server.name
  }
}

data "external" "kubeconfig_raw" {
  program = ["${path.module}/scripts/fetch-kubeconfig.sh"]
  query = {
    name      = multipass_instance.server.name
    server_ip = multipass_instance.server.ipv4
  }
}

resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig"
  content         = data.external.kubeconfig_raw.result.content
  file_permission = "0600"
}
