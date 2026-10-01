#cloud-config
package_update: true
runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${k3s_channel} K3S_URL=https://${server_ip}:6443 K3S_TOKEN=${k3s_token} sh -s - agent
  - until systemctl is-active --quiet k3s-agent; do sleep 2; done
  - touch /tmp/k3s-ready
