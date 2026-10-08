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
- **Workload manifests must never live under `gitops/apps/**`.** The
  bootstrap `app-of-apps` Application recurses that whole tree
  (`directory: { recurse: true }`), so anything placed there gets
  applied twice — once by its own ArgoCD Application, once by
  app-of-apps directly — and the two fight over ownership
  (`OutOfSync` ping-pong). Actual workload YAML (the podinfo `Rollout`/
  `Service`, and any future app's manifests) goes under
  `gitops/manifests/<app>/`, outside that recursed tree; only the
  `Application` CR itself lives under `gitops/apps/<app>/`. See
  `docs/superpowers/plans/2026-10-08-podinfo-canary-rollout.md`'s
  "Layout adjustment vs. the spec" section for the full reasoning.
- Podinfo is canary-deployed via Argo Rollouts (a `Rollout`, not a
  `Deployment` — the upstream podinfo Helm chart only ever renders a
  `Deployment`, so podinfo's manifests are hand-authored, not
  chart-sourced). On this Mac's kubectl v1.37.0 +
  kubectl-argo-rollouts v1.10.0, the plugin only dispatches via
  `kubectl argo rollouts <cmd>` (two tokens) — the single-hyphen
  `kubectl argo-rollouts <cmd>` form shown in upstream's own docs
  fails with "unknown command". See README's Canary deployments
  section.

## Layout

- `terraform/` — all infra: VM provisioning (`cluster.tf`), k3s
  bootstrap/kubeconfig retrieval (`k3s.tf`), ArgoCD install + bootstrap
  Application (`argocd.tf`).
- `gitops/bootstrap/app-of-apps.yaml` — Terraform-templated (has
  `${...}` placeholders), applied directly by Terraform. Not synced by
  ArgoCD itself.
- `gitops/apps/` — `Application` CRs only, reconciled by ArgoCD from
  git (Terraform never touches this after the first apply). Includes
  `argo-rollouts/` (installs the Argo Rollouts controller + CRDs) and
  `podinfo/` (points at `gitops/manifests/podinfo/`).
- `gitops/manifests/` — actual workload manifests (currently just
  `podinfo/rollout.yaml` + `service.yaml`). Deliberately *outside* the
  tree app-of-apps recurses — see the critical gotcha above.

## Dependency versions

Per standing instructions: always use the latest stable version of a
dependency unless told otherwise, never downgrade without approval. The
provider versions pinned in `terraform/versions.tf` were the latest
stable releases as of 2026-10-01 — re-check the registry before reusing
them if this project is picked up much later.
