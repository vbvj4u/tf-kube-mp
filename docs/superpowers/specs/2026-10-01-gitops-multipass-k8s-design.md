# GitOps-managed Kubernetes on Multipass — Design Spec

- **Date**: 2026-10-01
- **Status**: Approved (design), pending implementation plan
- **Owner**: Vijay

## 1. Intent

Stand up a local, repeatable Kubernetes dev environment on a Mac:
Terraform provisions Multipass VMs and bootstraps a Kubernetes cluster,
then installs ArgoCD, which takes over deploying a sample app
(podinfo) via GitOps from a GitHub repo. Terraform's responsibility
ends at "cluster exists + ArgoCD is running and pointed at git";
ArgoCD owns everything deployed to the cluster from that point on.

### Success criteria
- `terraform apply` in `terraform/` produces a working multi-node
  Kubernetes cluster on Multipass and a running ArgoCD instance,
  with no manual steps beyond running `terraform apply`.
- ArgoCD is already syncing podinfo from the GitHub repo by the time
  `apply` finishes.
- Editing `gitops/apps/podinfo/values.yaml` in GitHub and pushing is
  sufficient to change what's running in the cluster — no
  `terraform apply`, no `kubectl`, no SSH.
- `terraform destroy` returns the Mac to its pre-`apply` state (no
  leftover VMs, disk usage, or local generated files), except for the
  GitHub repo itself, which is intentionally outside Terraform's
  lifecycle.

## 2. Architecture overview

```
Mac host
  terraform apply
     |
     +--> Multipass VMs (larstobi/multipass provider)
     |      - k3s-server   (control plane, 1 node)
     |      - k3s-worker-0 (agent)
     |      - k3s-worker-1 (agent)
     |      cloud-init on each installs k3s via get.k3s.io
     |
     +--> data.external: `multipass exec` polls server readiness,
     |    then pulls the k3s node-token, fed into worker cloud-init
     |
     +--> data.external + local_file: `multipass transfer` pulls
     |    /etc/rancher/k3s/k3s.yaml -> ./terraform/kubeconfig
     |    (server: 127.0.0.1 rewritten to the server VM's real IP)
     |
     +--> helm_release "argocd" (Helm provider, config_path =
     |    ./terraform/kubeconfig) — installs the argo-cd chart
     |
     +--> one bootstrap Application manifest (kubectl_manifest,
          gavinbunney/kubectl provider) pointing ArgoCD at this
          repo's /gitops/apps directory

        | (git push, one-time + whenever /gitops is edited)
        v
  github.com/vbvj4u/tf-kube-mp (public)
    /terraform   -- everything above
    /gitops
      bootstrap/app-of-apps.yaml   (the one Application Terraform applies)
      apps/podinfo/                (what ArgoCD actually syncs)
         |
         v (ArgoCD polls/syncs from here — NOT Terraform)
  podinfo running in the cluster, exposed via a NodePort Service
```

Key principle: Terraform applies exactly one ArgoCD `Application`
resource (the bootstrap / "app of apps"). Everything under
`gitops/apps/` is reconciled by ArgoCD continuously from git; Terraform
never touches those resources again after the first apply.

## 3. Key decisions and rejected alternatives

| Decision | Chosen | Rejected alternative(s) | Why |
|---|---|---|---|
| K8s distro/bootstrap | k3s | kubeadm (vanilla) | Lightweight, single binary, built-in HA story, far less cloud-init complexity; no HAProxy or CRI-shim hacks needed on a laptop |
| Cluster topology | 1 control-plane + 2 workers | 1+3, or 3-master HA | Leanest footprint for a Mac; variable-driven so it's trivial to scale later |
| Multipass automation | `larstobi/multipass` Terraform provider (native `instance` resource) | Python `data.external` shim (reference repo's approach) | A real provider now exists (confirmed on the Terraform Registry, latest 1.4.3); no reason to replicate a 2023 workaround |
| VM post-boot access | `multipass exec` / `multipass transfer` via `local-exec` and `data.external` | SSH (reference repo's approach: injected keypair, remote-exec) | Everything runs on one Mac; Multipass's own exec/transfer needs no key management and has no SSH-readiness race |
| Container runtime | containerd (k3s's bundled default) | Docker + `cri-dockerd` built from source | containerd is the standard CRI since K8s 1.24+; the reference repo's from-source shim build is unnecessary cruft |
| ArgoCD install | Terraform `helm_release` against the official `argo-helm` chart | Static `install.yaml` via `kubectl`/`kubernetes_manifest`; separate post-`apply` script | Declarative, versioned, stays in the same `terraform apply` as everything else |
| Bootstrap Application apply mechanism | `kubectl_manifest` (gavinbunney/kubectl provider) | official `kubernetes_manifest` (hashicorp) | Handles applying a CR whose CRD was installed earlier in the *same* apply far more reliably |
| GitOps repo location | This repo (`tf-kube-mp`), pushed to GitHub, `/gitops` subdirectory | A second dedicated repo; fully local git server | Simplest; one repo to manage for a personal project |
| Repo visibility | Public | Private | No repo credentials/secrets needed in ArgoCD; simplest setup |
| Repo creation | Pushed once by hand (or by Claude, with confirmation), outside Terraform | `integrations/github` Terraform provider creating the repo | Terraform can't push this project's own files into itself in the same apply that depends on them existing — would be circular |
| Sample app | podinfo (upstream Helm chart) | Plain nginx hello-world; k8s guestbook | Built for exactly this demo purpose; visually confirms GitOps rollouts |
| App exposure | Service `type: NodePort` | Ingress/IngressRoute via k3s's bundled Traefik | Zero extra DNS/ingress-host config needed for a demo |
| ArgoCD cascade-delete finalizer | Not added | `resources-finalizer.argocd.argoproj.io` on the Application | The whole cluster is destroyed on `terraform destroy` anyway; waiting for ArgoCD to prune podinfo first only slows destroy down |
| Kubeconfig file lifecycle | `local_file` resource (content from `data.external`) | Bare `local-exec` writing the file | `local_file`-managed files are deleted by Terraform on `destroy`; bare `local-exec` output is not |

## 4. Repo & module layout

```
tf-kube-mp/
├── CLAUDE.md
├── README.md
├── .gitignore                  # kubeconfig, .terraform/, *.tfstate*
├── docs/superpowers/specs/     # this file
├── terraform/
│   ├── versions.tf             # provider requirements: multipass (larstobi),
│   │                           #   helm, kubectl (gavinbunney), kubernetes,
│   │                           #   local, null, external
│   ├── variables.tf            # masters(=1), workers(=2), cpu, mem, disk,
│   │                           #   k3s_channel, argocd_chart_version,
│   │                           #   gitops_repo_url, gitops_repo_revision
│   ├── cluster.tf              # multipass_instance: server + workers,
│   │                           #   cloud-init wiring
│   ├── k3s.tf                  # data.external (readiness poll + token
│   │                           #   retrieval), local_file.kubeconfig
│   ├── argocd.tf                # helm_release "argocd" + kubectl_manifest
│   │                           #   for the bootstrap Application
│   ├── outputs.tf               # node IPs, kubeconfig path, ArgoCD admin
│   │                           #   password, ArgoCD URL
│   └── templates/
│       ├── cloud-init-server.yaml.tpl
│       └── cloud-init-worker.yaml.tpl
└── gitops/
    ├── bootstrap/
    │   └── app-of-apps.yaml     # the single Application Terraform applies,
    │                           #   pointing at ./gitops/apps
    └── apps/
        └── podinfo/
            ├── application.yaml  # Application for podinfo: upstream Helm
            │                     #   chart + local values.yaml
            └── values.yaml
```

## 5. Terraform data flow (sequencing)

1. `multipass_instance.server` launches with `cloud-init-server.yaml.tpl`
   (rendered via `templatefile()`) — installs k3s in server mode
   (`curl -sfL https://get.k3s.io | sh -s - server --cluster-init`),
   writes `/tmp/k3s-ready` once `k3s.yaml` exists and the node is `Ready`.
2. `data.external.k3s_token` (`depends_on` the server) polls via
   `multipass exec k3s-server -- test -f /tmp/k3s-ready` in a retry
   loop (timeout ~5 min, clear error on timeout), then reads
   `/var/lib/rancher/k3s/server/node-token`.
3. `multipass_instance.worker[count.index]` (count = `var.workers`)
   launches with `cloud-init-worker.yaml.tpl`, templated with the
   server's `ipv4` output and the token from step 2 (`K3S_URL`,
   `K3S_TOKEN` env vars for the k3s agent installer).
4. `data.external.kubeconfig_raw` runs `multipass transfer
   k3s-server:/etc/rancher/k3s/k3s.yaml -` (to stdout) and rewrites
   `127.0.0.1` to the server's real `ipv4`; `resource "local_file"
   "kubeconfig"` writes the result to `./terraform/kubeconfig`.
5. `provider "helm"` and `provider "kubectl"` both set
   `config_path = local_file.kubeconfig.filename`, with
   `depends_on` ensuring neither runs before the file exists.
6. `helm_release "argocd"` installs the `argo-cd` chart from
   `https://argoproj.github.io/argo-helm` into the `argocd` namespace.
   Chart version left unpinned (resolves to latest at apply time)
   unless a version is explicitly supplied as a variable.
7. `kubectl_manifest "bootstrap_app"` applies
   `gitops/bootstrap/app-of-apps.yaml`, with `gitops_repo_url` and
   `gitops_repo_revision` templated in from variables.
   `depends_on = [helm_release.argocd]`.
8. Outputs: server/worker IPs, kubeconfig path, and the ArgoCD initial
   admin password (read via a `kubernetes_secret` data source against
   `argocd-initial-admin-secret`).

From this point, ArgoCD polls/syncs the GitHub repo itself — nothing
in steps 1–8 runs again unless `terraform apply` is re-run (e.g. to
resize the cluster) or the bootstrap Application's target revision
changes.

## 6. GitOps repo structure & sample app

- `gitops/bootstrap/app-of-apps.yaml`: one `Application`,
  `source.path: gitops/apps`, `source.repoURL`/`targetRevision`
  templated from Terraform variables, `destination` = the in-cluster
  API server, `syncPolicy.automated.selfHeal: true`. The only
  manifest Terraform applies directly.
- `gitops/apps/podinfo/application.yaml`: a second `Application`,
  committed to git (ArgoCD discovers it because it lives under the
  path the app-of-apps watches — Terraform never applies this one),
  pointing at upstream podinfo's Helm chart
  (`https://stefanprodan.github.io/podinfo`) with a local
  `values.yaml` for overrides (replica count, resource requests sized
  for a laptop VM).
- Exposure: podinfo's chart `service.type` set to `NodePort` in
  `values.yaml` so it's reachable from the Mac browser at
  `http://<worker-ip>:<nodeport>` with no extra ingress/DNS config.
- The actual GitOps proof: editing `values.yaml` in GitHub (e.g.
  bumping replicas or the image tag) and pushing is sufficient to
  change the running app — no `terraform apply`, no `kubectl apply`.

## 7. Error handling & edge cases

- **Boot/readiness races**: readiness is polled via a sentinel file
  and retry loop (see §5 step 2), not a fixed sleep, since cloud-init
  timing varies by Mac hardware.
- **Worker join failures**: non-fatal to the rest of the stack (ArgoCD
  and podinfo only need the server + at least one worker). A failed
  join surfaces as a missing node in `kubectl get nodes` / the
  Terraform outputs; recoverable via `terraform taint` + re-apply of
  that one instance. No automatic retry built in.
- **Helm/ArgoCD install failures**: handled by `helm_release`'s
  built-in `timeout` and rollback-on-failure behavior — surfaces as a
  normal Terraform apply error.
- **Idempotency / resizing**: every Multipass instance input
  (`cpus`, `memory`, `disk`, `image`, `cloudinit_file`) forces
  replacement (`RequiresReplace`). Changing `var.workers` only
  touches the added/removed worker instances; changing a shared
  variable like `cpus` replaces *all* instances. Documented in the
  README rather than engineered around.
- **GitHub repo unreachable**: surfaces inside ArgoCD as a
  degraded/`Unknown` Application — does not block Terraform, since
  Terraform only templates the repo URL string into the bootstrap
  manifest and never validates reachability itself.
- **`terraform destroy`**: resources are destroyed in reverse
  dependency order, so `kubectl_manifest` and `helm_release` are torn
  down *before* the VMs, while the cluster is still live to process
  the deletes. The Multipass provider's `Delete` calls
  `multipass delete --purge`, so VM disk space is freed immediately
  with no manual `multipass purge` step. The local kubeconfig file is
  a `local_file` resource, so it's removed from disk on destroy too.
  The GitHub repo and its history are untouched by destroy, by design.

## 8. Variables / configurability

`terraform/variables.tf`: `masters` (default 1), `workers` (default
2), `cpus`, `memory`, `disk` (laptop-sane defaults: 2 CPU / 2GiB /
10GiB per node), `k3s_channel` (default `stable`, resolved to latest
at apply time), `argocd_chart_version` (default unset — Helm provider
resolves latest unless pinned), `gitops_repo_url`,
`gitops_repo_revision` (default `main`).

Per Vijay's dependency-management rules: no version is hardcoded
"latest-as-of-today" in this spec. Implementation resolves actual
latest stable versions (k3s channel, argo-helm chart, provider
versions) at build time, and any version pin requires explicit
approval before being treated as a floor/ceiling.

## 9. Testing / validation plan

No application code to unit-test; validation is a scripted pass after
`terraform apply`:

1. `terraform output` — all node IPs, kubeconfig path, ArgoCD admin
   password.
2. `KUBECONFIG=./terraform/kubeconfig kubectl get nodes` — expect 1
   Ready control-plane + N Ready workers.
3. `kubectl get applications -n argocd` — expect `app-of-apps` and
   `podinfo` both `Synced`/`Healthy`.
4. Hit podinfo's NodePort URL in a browser — confirm the UI loads.
5. Edit `gitops/apps/podinfo/values.yaml` in the GitHub repo (bump
   replicas), push, watch `kubectl get pods -n podinfo -w` pick up the
   change within ArgoCD's sync interval — no `terraform apply`
   involved. This is the actual GitOps proof, not just "did Helm
   install succeed."
6. `terraform destroy`, then confirm `multipass list` shows no
   leftover instances and `./terraform/kubeconfig` is gone.

## 10. Out of scope (for this spec)

- Multi-master HA (deferred; `masters` variable exists for future use
  but only `masters = 1` is implemented now).
- Private-repo credentials / ArgoCD repo secrets (repo is public).
- Ingress/TLS for podinfo (NodePort only).
- CI for the Terraform code itself (no GitHub Actions pipeline in this
  pass).
