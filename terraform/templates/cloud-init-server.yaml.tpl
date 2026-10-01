#cloud-config
package_update: true
runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${k3s_channel} sh -s - server
  - until systemctl is-active --quiet k3s; do sleep 2; done
  - until test -s /var/lib/rancher/k3s/server/node-token; do sleep 2; done
  - chown ubuntu:ubuntu /etc/rancher/k3s/k3s.yaml
  - touch /tmp/k3s-ready
