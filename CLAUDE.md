# tf-kube-mp

Terraform-provisioned k3s cluster on Multipass (macOS) that bootstraps
ArgoCD and hands off to GitOps. Full design: `docs/superpowers/specs/2026-10-01-gitops-multipass-k8s-design.md`.
Implementation plan and ledger: `docs/superpowers/plans/2026-10-01-gitops-multipass-k8s.md`.

## Critical gotchas

- **Always run `terraform apply`/`destroy` with `-parallelism=1`.**
  Concurrent Multipass VM launches have been observed to race and hand
  out duplicate IPs. Not optional.
- **`jq` is a hard dependency** of the `data.external` scripts in
  `terraform/scripts/` (they talk to Multipass via `multipass exec`/
  `multipass transfer`, not SSH).
- The `kubernetes`/`helm`/`kubectl` Terraform providers are configured
  from **parsed kubeconfig values** (`yamldecode()` in `terraform/argocd.tf`),
  not `config_path`. `config_path` eagerly stats the file before any
  resource is created, which breaks a from-scratch apply when
  `terraform/kubeconfig` doesn't exist yet. Don't revert this.
- Anything holding a secret (`cloud_init_worker`, `kubeconfig`) must be
  `local_sensitive_file`, not `local_file` — `local_file` defaults to
  world-readable permissions and prints its content unredacted in CLI
  output.
- `terraform.tfstate` holds the k3s join token and cluster-admin
  kubeconfig in cleartext. Gitignored by design; see README's Security
  notes.

## Layout

- `terraform/` — all infra: VM provisioning (`cluster.tf`), k3s
  bootstrap/kubeconfig retrieval (`k3s.tf`), ArgoCD install + bootstrap
  Application (`argocd.tf`).
- `gitops/bootstrap/app-of-apps.yaml` — Terraform-templated (has
  `${...}` placeholders), applied directly by Terraform. Not synced by
  ArgoCD itself.
- `gitops/apps/` — everything ArgoCD actually reconciles from git.
  Terraform never touches this after the first apply.

## Dependency versions

Per standing instructions: always use the latest stable version of a
dependency unless told otherwise, never downgrade without approval. The
provider versions pinned in `terraform/versions.tf` were the latest
stable releases as of 2026-10-01 — re-check the registry before reusing
them if this project is picked up much later.
