# tf-kube-mp

Terraform-provisioned k3s cluster on Multipass (macOS), bootstrapped with
ArgoCD, managing a sample app (podinfo) entirely via GitOps.

See `docs/superpowers/specs/2026-10-01-gitops-multipass-k8s-design.md` for
the full design and rationale.

## Prerequisites

- [Multipass](https://multipass.run/) installed, with its daemon running
  (`multipass list` should print a table, not an error)
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.9
- `kubectl`
- `jq` — required by the `data.external` scripts under `terraform/scripts/`
  that talk to Multipass
- [`gh`](https://cli.github.com/), authenticated, only if you're pushing
  changes to the GitHub repo ArgoCD watches

## Usage

```bash
cd terraform
terraform init
terraform apply -parallelism=1
```

**Always pass `-parallelism=1`.** Launching more than one Multipass VM
concurrently has been observed to race on IP assignment (two VMs getting
the same address) — serializing creation avoids this entirely at the cost
of a slightly longer apply.

This provisions 1 k3s server + 2 k3s worker VMs on Multipass, installs
ArgoCD via Helm, and applies one bootstrap `Application` pointing at this
repo's `gitops/apps` directory. ArgoCD then deploys podinfo on its own.

Useful outputs (still from inside `terraform/`):

```bash
terraform output podinfo_url            # open in a browser
terraform output -raw argocd_admin_password
KUBECONFIG=kubeconfig kubectl get nodes
```

To change what's deployed, edit files under `gitops/apps/`, commit, and
push — no `terraform apply` needed. Only changes to `terraform/` itself
(cluster size, VM resources, ArgoCD version) need a re-apply.

### Accessing the ArgoCD UI

`argocd-server` is only a `ClusterIP` Service (the Helm chart's default —
no ingress/NodePort is configured for it), so reach it via port-forward:

```bash
KUBECONFIG=terraform/kubeconfig kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Then open `https://localhost:8080`, log in as `admin` with the password
from `terraform output -raw argocd_admin_password`.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `masters` | `1` | Only `1` is currently supported |
| `workers` | `2` | |
| `cpus` / `memory` / `disk` | `2` / `2GiB` / `10GiB` | Per VM. Changing a shared variable like `cpus` replaces *every* VM, not just new ones |
| `k3s_channel` | `stable` | |
| `argocd_chart_version` | `""` (latest) | |
| `gitops_repo_url` / `gitops_repo_revision` | this repo / `main` | |

## Security notes

- `terraform/terraform.tfstate` holds cluster credentials in cleartext
  (the k3s join token and the full cluster-admin kubeconfig) — this is
  normal for Terraform's local backend, but the file is gitignored
  deliberately and should stay off any shared filesystem. Consider
  `chmod 600 terraform/terraform.tfstate`.
- The k3s join token is ephemeral: it's regenerated fresh every time the
  server VM is (re)created, and it only grants join access to VMs on this
  Mac's own Multipass network, never exposed externally.
- `terraform/kubeconfig` and the per-worker cloud-init files are written
  with restrictive permissions (`0600`) via `local_sensitive_file`, which
  also keeps their content out of `terraform plan`/`apply` output.

## Troubleshooting

- **A worker or the server never reaches Ready**: cloud-init bounds its
  own readiness wait (240s for the k3s/k3s-agent systemd unit), so
  `terraform apply` will eventually fail on that VM rather than hang
  forever. Check the reason with
  `multipass exec <name> -- cat /tmp/k3s-failed` (if cloud-init gave up)
  or `multipass exec <name> -- sudo journalctl -u k3s[-agent] --no-pager`.
- **A VM exists in `multipass list` but not in Terraform state** (can
  happen if a previous apply was interrupted mid-launch): remove it by
  hand with `multipass delete --purge <name>`, then re-run
  `terraform apply -parallelism=1`.
- **`podinfo` Application stuck `OutOfSync`/`Degraded`**: check
  `kubectl get application podinfo -n argocd -o yaml` for
  `status.conditions`. On a from-scratch apply this is usually the
  `argo-rollouts` Application not having synced yet (so the `Rollout`
  CRD doesn't exist) — it resolves itself once `argo-rollouts` finishes
  syncing. Otherwise, check for a YAML syntax error in
  `gitops/manifests/podinfo/*.yaml`.
- **`argo-rollouts` Application stuck `OutOfSync`/`Degraded`**: check
  `kubectl get application argo-rollouts -n argocd -o yaml` for
  `status.conditions`.

## Canary deployments

Podinfo is managed by an [Argo Rollouts](https://argo-rollouts.readthedocs.io/)
`Rollout` instead of a plain `Deployment`. Its canary strategy steps to
`setWeight: 33` — 2 stable pods / 1 canary pod behind the same NodePort
Service — then pauses indefinitely.

Install the CLI plugin once:

```bash
brew install argoproj/tap/kubectl-argo-rollouts
```

To run a canary:

1. Bump the image tag in `gitops/manifests/podinfo/rollout.yaml`,
   commit, push.
2. Watch it reach the paused canary split:
   ```bash
   KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts get rollout podinfo -n podinfo --watch
   ```
3. Promote (finish the rollout) or abort (stop sending traffic to the
   canary):
   ```bash
   KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts promote podinfo -n podinfo
   KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts abort podinfo -n podinfo
   ```

**`abort` is transient, not a GitOps rollback.** It only patches the
live Rollout's `status`, not the manifest in git. Since podinfo's
Application has `syncPolicy.automated.selfHeal: true`, ArgoCD keeps
reconciling toward whatever image tag is committed in git — `abort`
stops traffic to the canary immediately (useful mid-incident) but
doesn't survive the next sync unless you also revert the git commit
that bumped the tag. For a durable rollback, revert the commit and
push.

## Teardown

```bash
cd terraform
terraform destroy -parallelism=1
```

Removes all VMs (purged immediately, no leftover disk usage) and the
local `terraform/kubeconfig` file. The GitHub repo is untouched — it's
outside Terraform's lifecycle by design.
