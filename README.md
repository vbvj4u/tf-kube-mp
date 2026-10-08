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

To change what's deployed, edit files under `gitops/apps/` (Application
definitions) or `gitops/manifests/` (the actual workload YAML, e.g.
podinfo's image tag in `gitops/manifests/podinfo/rollout.yaml`), commit,
and push — no `terraform apply` needed. Only changes to `terraform/`
itself (cluster size, VM resources, ArgoCD version) need a re-apply.

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
- **`podinfo` Application not `Healthy`** (sync status may still say
  `Synced`): run `kubectl argo rollouts get rollout podinfo -n podinfo`
  before assuming something's broken — it names the real cause:
  - **`Paused` / `CanaryPauseStep`** — expected, not a fault. A canary
    is mid-rollout, holding at the `setWeight: 33` split until you
    `promote` or `abort` it (see Canary deployments below).
    `podinfo`'s Application shows not-`Healthy` for the whole duration
    of a deliberate pause.
  - **`Degraded` / `RolloutAborted`, with sync status `Synced`** —
    someone ran `abort`. This can persist indefinitely: `abort` only
    changes live status, so git and the cluster disagree and ArgoCD
    has no drift to resync. See the `abort` caveat below.
  - **Neither of the above, and genuinely `OutOfSync`/`Degraded`**: on
    a from-scratch apply this is usually the `argo-rollouts`
    Application not having synced yet (so the `Rollout` CRD doesn't
    exist) — it resolves itself once `argo-rollouts` finishes syncing.
    Otherwise, check for a YAML syntax error in
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
   KUBECONFIG=terraform/kubeconfig kubectl argo rollouts get rollout podinfo -n podinfo --watch
   ```
3. Promote (finish the rollout) or abort (stop sending traffic to the
   canary):
   ```bash
   KUBECONFIG=terraform/kubeconfig kubectl argo rollouts promote podinfo -n podinfo
   KUBECONFIG=terraform/kubeconfig kubectl argo rollouts abort podinfo -n podinfo
   ```

   (Note the space, not a hyphen, between `argo` and `rollouts` —
   on at least kubectl v1.37.0, `kubectl argo-rollouts ...` (as
   upstream's own docs show it) fails with `unknown command
   "argo-rollouts" for "kubectl"`; kubectl's plugin dispatch resolves
   the `kubectl-argo-rollouts` binary via the two-word form instead.)

**`abort` is transient and can leave git and the cluster silently
disagreeing.** It only patches the live Rollout's `status`, not the
manifest in git, so the pods return to the stable version immediately
— good for stopping traffic to a bad canary mid-incident. But because
`.spec` never changed, ArgoCD still reports the Application `Synced`
(there's no drift for `selfHeal` to detect) even though git still
names the bumped tag. Nothing re-reconciles on its own, and the
disagreement is invisible to a quick "is everything green?" check —
the next unrelated change to `rollout.yaml` will roll straight forward
to the version you just aborted. For a durable rollback, revert the
commit and push instead, so git tells the truth.

A git revert is itself a new image change, so the canary strategy
re-triggers from scratch on the way back down too: it steps to
`setWeight: 33` and pauses indefinitely, just like a forward bump —
*unless* the live pods already matched the reverted version (e.g.
right after an `abort`), in which case there's nothing to transition
and it resolves straight to `Healthy`. If `kubectl argo rollouts get
rollout podinfo -n podinfo` still shows `Paused` after the revert
syncs, run `kubectl argo rollouts promote podinfo -n podinfo` once
more to finish returning to the reverted version.

## Teardown

```bash
cd terraform
terraform destroy -parallelism=1
```

Removes all VMs (purged immediately, no leftover disk usage) and the
local `terraform/kubeconfig` file. The GitHub repo is untouched — it's
outside Terraform's lifecycle by design.
