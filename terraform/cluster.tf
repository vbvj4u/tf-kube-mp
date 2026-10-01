resource "local_file" "cloud_init_server" {
  filename = "${path.module}/cloud-init-server.yaml"
  content = templatefile("${path.module}/templates/cloud-init-server.yaml.tpl", {
    k3s_channel = var.k3s_channel
  })
}

resource "local_file" "cloud_init_worker" {
  count    = var.workers
  filename = "${path.module}/cloud-init-worker-${count.index}.yaml"
  content = templatefile("${path.module}/templates/cloud-init-worker.yaml.tpl", {
    k3s_channel = var.k3s_channel
    server_ip   = multipass_instance.server.ipv4
    k3s_token   = data.external.k3s_token.result.token
  })
}

resource "multipass_instance" "server" {
  name           = "k3s-server"
  cpus           = var.cpus
  memory         = var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloud_init_server.filename
}

resource "multipass_instance" "worker" {
  count          = var.workers
  name           = "k3s-worker-${count.index}"
  cpus           = var.cpus
  memory         = var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloud_init_worker[count.index].filename
}
