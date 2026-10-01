data "external" "k3s_token" {
  program = ["${path.module}/scripts/k3s-wait-and-fetch-token.sh"]
  query = {
    name = multipass_instance.server.name
  }
}
