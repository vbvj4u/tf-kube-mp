# tf-kube-mp

Terraform-provisioned k3s cluster on Multipass (macOS), bootstrapped with
ArgoCD, managing a sample app (podinfo) entirely via GitOps.

See `docs/superpowers/specs/2026-10-01-gitops-multipass-k8s-design.md` for
the full design and rationale.

## Usage

```bash
cd terraform
terraform init
terraform apply
```

This provisions 1 k3s server + 2 k3s worker VMs on Multipass, installs
ArgoCD via Helm, and applies one bootstrap `Application` pointing at this
repo's `gitops/apps` directory. ArgoCD then deploys podinfo on its own.

Note: always pass `-parallelism=1`. Launching more than one Multipass VM
concurrently has been observed to race on IP assignment (two VMs getting
the same address) — serializing creation avoids this entirely at the cost
of a slightly longer apply.

Useful outputs (still from inside `terraform/`):

```bash
terraform output podinfo_url            # open in a browser
terraform output -raw argocd_admin_password
KUBECONFIG=kubeconfig kubectl get nodes
```

To change what's deployed, edit files under `gitops/apps/`, commit, and
push — no `terraform apply` needed. Only changes to `terraform/` itself
(cluster size, VM resources, ArgoCD version) need a re-apply.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `masters` | `1` | Only `1` is currently supported |
| `workers` | `2` | |
| `cpus` / `memory` / `disk` | `2` / `2GiB` / `10GiB` | Per VM. Changing a shared variable like `cpus` replaces *every* VM, not just new ones |
| `k3s_channel` | `stable` | |
| `argocd_chart_version` | `""` (latest) | |
| `gitops_repo_url` / `gitops_repo_revision` | this repo / `main` | |

## Teardown

```bash
cd terraform
terraform destroy -parallelism=1
```

Removes all VMs (purged immediately, no leftover disk usage) and the
local `terraform/kubeconfig` file. The GitHub repo is untouched — it's
outside Terraform's lifecycle by design.
