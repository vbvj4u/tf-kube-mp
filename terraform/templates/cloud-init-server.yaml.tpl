#cloud-config
package_update: true
runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${k3s_channel} sh -s - server
  - timeout 240 sh -c 'until systemctl is-active --quiet k3s; do sleep 2; done' || echo "k3s did not become active within 240s" > /tmp/k3s-failed
  - timeout 60 sh -c 'until test -s /var/lib/rancher/k3s/server/node-token; do sleep 2; done' || echo "node-token never appeared within 60s" > /tmp/k3s-failed
  - test -f /tmp/k3s-failed || chown ubuntu:ubuntu /etc/rancher/k3s/k3s.yaml
  - test -f /tmp/k3s-failed || touch /tmp/k3s-ready
