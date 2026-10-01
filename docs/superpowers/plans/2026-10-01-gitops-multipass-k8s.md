# GitOps-managed k3s on Multipass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `terraform apply` in `terraform/` stands up a k3s cluster on Multipass VMs and installs ArgoCD, which then deploys podinfo into the cluster purely from a GitHub repo — no `kubectl apply` by a human, ever, after the first `terraform apply`.

**Architecture:** Terraform provisions Multipass VMs via the `larstobi/multipass` provider, renders cloud-init that installs k3s directly (server then agents, token relayed through a `data.external` script using `multipass exec`), pulls the kubeconfig back to the host as a `local_file`, then uses the Helm and kubectl Terraform providers (pointed at that kubeconfig) to install ArgoCD and apply one bootstrap `Application`. Everything under `gitops/apps/` from that point on is reconciled by ArgoCD from git, never by Terraform.

**Tech Stack:** Terraform, the `larstobi/multipass`, `hashicorp/helm`, `gavinbunney/kubectl`, `hashicorp/kubernetes`, `hashicorp/local`, `hashicorp/external` providers, k3s, ArgoCD (argo-helm chart), podinfo, bash + jq (for `data.external` scripts), GitHub (`gh` CLI).

**Spec:** `docs/superpowers/specs/2026-10-01-gitops-multipass-k8s-design.md`

## Global Constraints

- Always use the latest stable version of every dependency (Terraform providers, k3s channel, Helm chart) unless Vijay explicitly pins one; never downgrade without his approval.
- No SSH keys, SSH provisioners, or SSH remote-exec anywhere. All VM access goes through `multipass exec` / `multipass transfer`.
- Container runtime is containerd (k3s's bundled default). Never introduce Docker or `cri-dockerd`.
- Only `masters = 1` is implemented. The variable exists for future use but any other value must be rejected by a Terraform `validation` block, not silently mishandled.
- The GitHub repo (`vbvj4u/tf-kube-mp`) is public, and is created/pushed once, by hand, outside Terraform's lifecycle. Terraform never creates, pushes to, or deletes the repo.
- ArgoCD's bootstrap `Application` is the only manifest Terraform ever applies directly. Everything under `gitops/apps/` is reconciled by ArgoCD from git and is never re-applied by Terraform.
- Applications do not carry ArgoCD's cascade-delete finalizer (`resources-finalizer.argocd.argoproj.io`).
- `terraform destroy` must leave no residue: VMs purged (not just "deleted"), local kubeconfig file removed from disk.

## Review Focus

- **Multipass unavailable or daemon not running**: `terraform init`/`apply` must fail with a clear, actionable error immediately, not hang. → Task 1 verifies Multipass responds before Terraform is even touched.
- **k3s install failure on the server node** (bad channel, network blip during cloud-init): the readiness-poll script must time out with an explicit error message, never loop forever or hand back an empty token. → Task 3's script has a bounded timeout, and the task's test step forces a timeout once to see the real failure message.
- **Worker join failure**: `terraform apply` can report success while a worker never actually joined (Terraform doesn't block on cloud-init finishing for workers, by design — see spec §7). This must be visible to whoever ran apply, not silently lost. → Task 3's verification step explicitly asserts the live node count equals `masters + workers`, not just "apply exited 0."
- **ArgoCD Application stuck `OutOfSync`/`Degraded` from a values-schema mistake** (e.g. a wrong Helm value key for podinfo): must be caught before the task is considered done. → Task 6 dry-run validates the manifests against the live API server's schema; Task 8 polls real sync/health status with a timeout rather than assuming success right after apply.
- **The GitOps round-trip is claimed to work without ever being exercised live**: the only real proof is editing a value in the pushed repo and watching the cluster change with zero `terraform apply`/`kubectl apply` in between. → Task 9 makes this an explicit, scripted before/after check, not an optional manual step.

---

## File Structure

```
tf-kube-mp/
├── .gitignore
├── README.md
├── docs/superpowers/{specs,plans}/...
├── terraform/
│   ├── versions.tf
│   ├── variables.tf
│   ├── cluster.tf          # cloud-init rendering + multipass_instance (server, worker)
│   ├── k3s.tf               # token + kubeconfig retrieval (data.external, local_file)
│   ├── argocd.tf             # helm/kubernetes/kubectl providers, helm_release, bootstrap Application
│   ├── outputs.tf
│   ├── scripts/
│   │   ├── k3s-wait-and-fetch-token.sh
│   │   └── fetch-kubeconfig.sh
│   └── templates/
│       ├── cloud-init-server.yaml.tpl
│       └── cloud-init-worker.yaml.tpl
└── gitops/
    ├── bootstrap/
    │   └── app-of-apps.yaml   # Terraform-templated; applied directly by kubectl_manifest
    └── apps/
        └── podinfo/
            ├── application.yaml   # synced by ArgoCD from git, never applied by Terraform
            └── values.yaml
```

---

### Task 1: Project scaffolding and provider versions

**Files:**
- Create: `.gitignore`
- Create: `terraform/versions.tf`

**Interfaces:**
- Produces: a `terraform/` directory where `terraform init` succeeds with all required providers installed. Every later task runs `terraform` commands from inside `terraform/`.

- [ ] **Step 1: Confirm Multipass is actually responsive before touching Terraform**

Run: `multipass list`
Expected: exits 0 and prints a table (even if empty/showing unrelated VMs). If this fails or hangs, stop — Multipass itself is broken and no Terraform step will work until that's fixed.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
.terraform/
*.tfstate
*.tfstate.*
terraform/kubeconfig
terraform/cloud-init-server.yaml
terraform/cloud-init-worker-*.yaml
crash.log
```

- [ ] **Step 3: Write `terraform/versions.tf`**

Versions below are the latest stable releases on the Terraform Registry as of 2026-10-01. If this task is executed later than that, re-check each provider's latest version on the registry before pinning — do not reuse these numbers blindly.

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    multipass = {
      source  = "larstobi/multipass"
      version = "1.4.3"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.9.1"
    }
    external = {
      source  = "hashicorp/external"
      version = "2.4.2"
    }
  }
}
```

- [ ] **Step 4: Run `terraform init` and verify it succeeds**

Run: `terraform -chdir=terraform init`
Expected: `Terraform has been successfully initialized!`, all six providers listed as installed, and a `terraform/.terraform.lock.hcl` file created.

- [ ] **Step 5: Commit**

```bash
git add .gitignore terraform/versions.tf terraform/.terraform.lock.hcl
git commit -m "Scaffold terraform/ with pinned provider versions"
```

---

### Task 2: Variables and cloud-init templates

**Files:**
- Create: `terraform/variables.tf`
- Create: `terraform/templates/cloud-init-server.yaml.tpl`
- Create: `terraform/templates/cloud-init-worker.yaml.tpl`

**Interfaces:**
- Produces: `var.masters`, `var.workers`, `var.cpus`, `var.memory`, `var.disk`, `var.k3s_channel`, `var.argocd_chart_version`, `var.gitops_repo_url`, `var.gitops_repo_revision` — every later task's `.tf` file references these exact names.
- Produces: `templates/cloud-init-server.yaml.tpl` taking `{ k3s_channel }`; `templates/cloud-init-worker.yaml.tpl` taking `{ k3s_channel, server_ip, k3s_token }`. Task 3 renders both via `templatefile()`.

- [ ] **Step 1: Write `terraform/variables.tf`**

```hcl
variable "masters" {
  type        = number
  default     = 1
  description = "Number of control-plane (k3s server) nodes. Only 1 is currently supported."

  validation {
    condition     = var.masters == 1
    error_message = "Multi-master is not yet implemented; masters must be 1."
  }
}

variable "workers" {
  type        = number
  default     = 2
  description = "Number of worker (k3s agent) nodes."

  validation {
    condition     = var.workers >= 1
    error_message = "At least 1 worker is required."
  }
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Number of vCPUs per VM."
}

variable "memory" {
  type        = string
  default     = "2GiB"
  description = "Memory per VM (Multipass size string, e.g. 2GiB)."
}

variable "disk" {
  type        = string
  default     = "10GiB"
  description = "Disk size per VM (Multipass size string, e.g. 10GiB)."
}

variable "k3s_channel" {
  type        = string
  default     = "stable"
  description = "k3s release channel (see https://update.k3s.io/v1-release/channels)."
}

variable "argocd_chart_version" {
  type        = string
  default     = ""
  description = "Pin the argo-cd Helm chart version. Empty string resolves to the latest chart version at apply time."
}

variable "gitops_repo_url" {
  type        = string
  default     = "https://github.com/vbvj4u/tf-kube-mp.git"
  description = "Git repository ArgoCD's bootstrap Application watches."
}

variable "gitops_repo_revision" {
  type        = string
  default     = "main"
  description = "Git revision (branch/tag) ArgoCD's bootstrap Application tracks."
}
```

- [ ] **Step 2: Write `terraform/templates/cloud-init-server.yaml.tpl`**

```yaml
#cloud-config
package_update: true
runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${k3s_channel} sh -s - server --write-kubeconfig-mode 644
  - until systemctl is-active --quiet k3s; do sleep 2; done
  - until test -s /var/lib/rancher/k3s/server/node-token; do sleep 2; done
  - touch /tmp/k3s-ready
```

- [ ] **Step 3: Write `terraform/templates/cloud-init-worker.yaml.tpl`**

```yaml
#cloud-config
package_update: true
runcmd:
  - curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${k3s_channel} K3S_URL=https://${server_ip}:6443 K3S_TOKEN=${k3s_token} sh -s - agent
  - until systemctl is-active --quiet k3s-agent; do sleep 2; done
  - touch /tmp/k3s-ready
```

- [ ] **Step 4: Validate the HCL and template syntax**

Run: `terraform -chdir=terraform fmt -check variables.tf && terraform -chdir=terraform validate`
Expected: `terraform validate` reports `Success! The configuration is valid.` (It can't yet check the templates themselves, since nothing references them — that happens in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add terraform/variables.tf terraform/templates/
git commit -m "Add cluster variables and k3s cloud-init templates"
```

---

### Task 3: Multipass VMs and the k3s cluster itself (first real apply)

**Files:**
- Create: `terraform/scripts/k3s-wait-and-fetch-token.sh`
- Create: `terraform/cluster.tf`
- Create: `terraform/k3s.tf`

**Interfaces:**
- Consumes: `var.cpus`, `var.memory`, `var.disk`, `var.k3s_channel`, `var.workers` (Task 2); `templates/cloud-init-server.yaml.tpl`, `templates/cloud-init-worker.yaml.tpl` (Task 2).
- Produces: `multipass_instance.server` (attributes `.name`, `.ipv4`); `multipass_instance.worker` (count-indexed, same attributes); `data.external.k3s_token.result.token`. Task 4 consumes `multipass_instance.server.name` and `.ipv4`; Task 9 consumes `multipass_instance.worker[*].ipv4`.

- [ ] **Step 1: Write `terraform/scripts/k3s-wait-and-fetch-token.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "NAME=\(.name)"')"

TIMEOUT=300
ELAPSED=0
until multipass exec "$NAME" -- test -f /tmp/k3s-ready; do
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Timed out after ${TIMEOUT}s waiting for $NAME to report k3s-ready" >&2
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

TOKEN=$(multipass exec "$NAME" -- sudo cat /var/lib/rancher/k3s/server/node-token)
jq -n --arg token "$TOKEN" '{token: $token}'
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x terraform/scripts/k3s-wait-and-fetch-token.sh`

- [ ] **Step 3: Write `terraform/cluster.tf`**

```hcl
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
```

- [ ] **Step 4: Write `terraform/k3s.tf`**

```hcl
data "external" "k3s_token" {
  program = ["${path.module}/scripts/k3s-wait-and-fetch-token.sh"]
  query = {
    name = multipass_instance.server.name
  }
}
```

- [ ] **Step 5: Validate**

Run: `terraform -chdir=terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Apply for real**

Run: `terraform -chdir=terraform apply`
Expected: plan shows `3 to add` (1 server + 2 workers, given default `workers = 2`), prompts for confirmation, then completes with `Apply complete! Resources: 3 added, 0 changed, 0 destroyed.` This will take several minutes — cloud-init has to download and install k3s on three fresh Ubuntu VMs.

- [ ] **Step 7: Verify the cluster is actually healthy (not just that `apply` exited 0)**

Run: `multipass exec k3s-server -- sudo kubectl get nodes`
Expected: exactly `1 + var.workers` lines (so 3 by default), every one showing `Ready`. If any worker is missing or `NotReady`, that worker's cloud-init failed — check `multipass exec k3s-worker-<n> -- sudo journalctl -u k3s-agent --no-pager | tail -50` before moving on; per the Global Constraints, a missing worker doesn't block the rest of the stack, but it must not go unnoticed here.

- [ ] **Step 8: Prove the timeout path in the token script actually fires (not just happy path)**

Run: `timeout 15 terraform/scripts/k3s-wait-and-fetch-token.sh <<< '{"name": "does-not-exist"}'; echo "exit: $?"`
Expected: the script errors out quickly (multipass reports the instance doesn't exist) rather than hanging — confirms the script fails loudly instead of silently when the target VM is wrong, which is the same code path that would fire on a real cloud-init failure.

- [ ] **Step 9: Commit**

```bash
git add terraform/cluster.tf terraform/k3s.tf terraform/scripts/
git commit -m "Provision k3s server/worker VMs via Multipass"
```

---

### Task 4: Kubeconfig retrieval to the host

**Files:**
- Create: `terraform/scripts/fetch-kubeconfig.sh`
- Modify: `terraform/k3s.tf` (append)

**Interfaces:**
- Consumes: `multipass_instance.server.name`, `multipass_instance.server.ipv4` (Task 3).
- Produces: `local_file.kubeconfig.filename` (always `"${path.module}/kubeconfig"`, i.e. `terraform/kubeconfig`). Tasks 5, 8, 9 all configure their providers/outputs against this exact path.

- [ ] **Step 1: Write `terraform/scripts/fetch-kubeconfig.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "NAME=\(.name) SERVER_IP=\(.server_ip)"')"

RAW=$(multipass transfer "${NAME}:/etc/rancher/k3s/k3s.yaml" -)
REWRITTEN=$(echo "$RAW" | sed "s/127.0.0.1/${SERVER_IP}/")

jq -n --arg content "$REWRITTEN" '{content: $content}'
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x terraform/scripts/fetch-kubeconfig.sh`

- [ ] **Step 3: Append to `terraform/k3s.tf`**

```hcl
data "external" "kubeconfig_raw" {
  program = ["${path.module}/scripts/fetch-kubeconfig.sh"]
  query = {
    name      = multipass_instance.server.name
    server_ip = multipass_instance.server.ipv4
  }
}

resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig"
  content         = data.external.kubeconfig_raw.result.content
  file_permission = "0600"
}
```

- [ ] **Step 4: Apply**

Run: `terraform -chdir=terraform apply`
Expected: `1 to add` (just `local_file.kubeconfig`), completes successfully, and `terraform/kubeconfig` now exists on disk.

- [ ] **Step 5: Verify external reachability and correct IP rewrite**

Run: `KUBECONFIG=terraform/kubeconfig kubectl get nodes`
Expected: same output as Task 3 Step 7 (1 Ready control-plane + N Ready workers), but this time reached directly from the Mac host over the network — not through `multipass exec`. If this hangs or connection-refuses, check `grep server terraform/kubeconfig` actually shows the VM's real IP (not `127.0.0.1`).

- [ ] **Step 6: Commit**

```bash
git add terraform/k3s.tf terraform/scripts/fetch-kubeconfig.sh
git commit -m "Retrieve k3s kubeconfig to the host as a managed local_file"
```

---

### Task 5: ArgoCD via Helm

**Files:**
- Create: `terraform/argocd.tf`
- Create: `terraform/outputs.tf`

**Interfaces:**
- Consumes: `local_file.kubeconfig.filename` (Task 4).
- Produces: `helm_release.argocd` (namespace `argocd`). Task 8 adds `depends_on = [helm_release.argocd]` to the bootstrap Application; Task 9 reads `data.kubernetes_secret.argocd_admin_password`.

- [ ] **Step 1: Write `terraform/argocd.tf`**

```hcl
provider "helm" {
  kubernetes {
    config_path = local_file.kubeconfig.filename
  }
}

provider "kubernetes" {
  config_path = local_file.kubeconfig.filename
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version != "" ? var.argocd_chart_version : null
  namespace        = "argocd"
  create_namespace = true

  depends_on = [local_file.kubeconfig]
}

data "kubernetes_secret" "argocd_admin_password" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}
```

- [ ] **Step 2: Write `terraform/outputs.tf`**

```hcl
output "server_ip" {
  value = multipass_instance.server.ipv4
}

output "worker_ips" {
  value = multipass_instance.worker[*].ipv4
}

output "kubeconfig_path" {
  value = local_file.kubeconfig.filename
}

output "argocd_admin_password" {
  value     = data.kubernetes_secret.argocd_admin_password.data["password"]
  sensitive = true
}
```

- [ ] **Step 3: Apply**

Run: `terraform -chdir=terraform apply`
Expected: adds the `argocd` namespace and the `argo-cd` Helm release; completes without error. This installs several Deployments, so it can take a minute or two for pods to actually become ready — that's checked next, not assumed here.

- [ ] **Step 4: Verify ArgoCD is actually running, not just that Helm reported success**

Run: `KUBECONFIG=terraform/kubeconfig kubectl -n argocd rollout status deploy/argocd-server --timeout=180s`
Expected: `deployment "argocd-server" successfully rolled out`.

Run: `terraform -chdir=terraform output -raw argocd_admin_password`
Expected: a non-empty string (the auto-generated initial admin password).

- [ ] **Step 5: Commit**

```bash
git add terraform/argocd.tf terraform/outputs.tf
git commit -m "Install ArgoCD via the Helm provider"
```

---

### Task 6: GitOps repo content — bootstrap and podinfo Applications

**Files:**
- Create: `gitops/bootstrap/app-of-apps.yaml`
- Create: `gitops/apps/podinfo/application.yaml`
- Create: `gitops/apps/podinfo/values.yaml`

**Interfaces:**
- Produces: `gitops/bootstrap/app-of-apps.yaml` — a Terraform `templatefile()` source (not raw YAML — it contains `${repo_url}`/`${revision}` placeholders) consumed by Task 8's `kubectl_manifest.bootstrap_app`. Produces the podinfo `Application` + `values.yaml`, which ArgoCD discovers on its own once Task 8's sync happens — Terraform never applies these two files directly.

- [ ] **Step 1: Write `gitops/bootstrap/app-of-apps.yaml`**

Note the `${...}` tokens: this file is rendered by Terraform's `templatefile()` in Task 8, not applied as-is. It lives under `gitops/` because conceptually it's the top of the GitOps tree, even though Terraform (not ArgoCD) applies it.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: ${revision}
    path: gitops/apps
    directory:
      recurse: true
      exclude: "**/values.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Write `gitops/apps/podinfo/values.yaml`**

```yaml
replicaCount: 2
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 128Mi
service:
  type: NodePort
  nodePort: 30080
```

- [ ] **Step 3: Write `gitops/apps/podinfo/application.yaml`**

This uses ArgoCD's multi-source `Application` feature: source 1 is podinfo's own published Helm chart repo, source 2 is this repo (referenced as `$values`) purely so `values.yaml` above can override the chart's defaults.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://stefanprodan.github.io/podinfo
      chart: podinfo
      targetRevision: ">=6.0.0"
      helm:
        valueFiles:
          - $values/gitops/apps/podinfo/values.yaml
    - repoURL: https://github.com/vbvj4u/tf-kube-mp.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Dry-run validate both manifests against the live cluster's API/schema**

Run (render the template with real values first, since it has `${...}` placeholders):

```bash
sed -e 's#\${repo_url}#https://github.com/vbvj4u/tf-kube-mp.git#' -e 's#\${revision}#main#' gitops/bootstrap/app-of-apps.yaml \
  | KUBECONFIG=terraform/kubeconfig kubectl apply --dry-run=server -f -
KUBECONFIG=terraform/kubeconfig kubectl apply --dry-run=server -f gitops/apps/podinfo/application.yaml
```

Expected: both report `... created (server dry run)` or `configured (server dry run)` with no schema errors. This confirms the Application CRD (installed by ArgoCD's Helm chart in Task 5) accepts both manifests' structure before anything is actually wired up to sync.

- [ ] **Step 5: Commit**

```bash
git add gitops/
git commit -m "Add app-of-apps bootstrap and podinfo Application manifests"
```

---

### Task 7: Push the repo to GitHub

**⚠️ Confirm with Vijay before running this task.** It creates a new public repository under his GitHub account (`vbvj4u`) and pushes this project's full history to it — a visible, shared action outside this machine. Do not run Step 2 or Step 3 without his explicit go-ahead in this session.

**Files:** none (repository-level operation only)

**Interfaces:**
- Produces: `https://github.com/vbvj4u/tf-kube-mp` — the live URL that `var.gitops_repo_url`'s default already assumes in Task 2. Task 8 depends on this repo actually existing and being reachable.

- [ ] **Step 1: Confirm with Vijay**

Ask him directly: "OK to create `github.com/vbvj4u/tf-kube-mp` as a public repo now and push everything committed so far?" Wait for an explicit yes before continuing.

- [ ] **Step 2: Create the repo and push**

Run:
```bash
gh repo create vbvj4u/tf-kube-mp --public --source=. --remote=origin
git push -u origin main
```
Expected: `gh` reports the repo created, `git push` reports `main -> main` with no errors.

- [ ] **Step 3: Verify**

Run: `gh repo view vbvj4u/tf-kube-mp --json visibility,url`
Expected: `"visibility": "PUBLIC"` and the URL matches `var.gitops_repo_url`'s default (`https://github.com/vbvj4u/tf-kube-mp.git`) minus the `.git` suffix.

(No separate commit step — the push itself is this task's deliverable.)

---

### Task 8: Wire up and apply the bootstrap Application

**Files:**
- Modify: `terraform/argocd.tf` (append)

**Interfaces:**
- Consumes: `var.gitops_repo_url`, `var.gitops_repo_revision` (Task 2); `gitops/bootstrap/app-of-apps.yaml` (Task 6); `helm_release.argocd` (Task 5); the pushed repo (Task 7).
- Produces: `kubectl_manifest.bootstrap_app`, the `app-of-apps` Application in the `argocd` namespace. Nothing later references this by name — its effect (the `podinfo` Application appearing) is what Task 9 checks for.

- [ ] **Step 1: Append to `terraform/argocd.tf`**

```hcl
provider "kubectl" {
  config_path = local_file.kubeconfig.filename
}

resource "kubectl_manifest" "bootstrap_app" {
  yaml_body = templatefile("${path.module}/../gitops/bootstrap/app-of-apps.yaml", {
    repo_url = var.gitops_repo_url
    revision = var.gitops_repo_revision
  })

  depends_on = [helm_release.argocd]
}
```

- [ ] **Step 2: Apply**

Run: `terraform -chdir=terraform apply`
Expected: adds `kubectl_manifest.bootstrap_app`, completes with no errors.

- [ ] **Step 3: Verify ArgoCD actually synced both the bootstrap app and the podinfo app it reveals — poll, don't assume**

Run:
```bash
for i in $(seq 1 30); do
  STATUS=$(KUBECONFIG=terraform/kubeconfig kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}')
  echo "$STATUS"
  echo "$STATUS" | grep -q "app-of-apps=Synced/Healthy" && echo "$STATUS" | grep -q "podinfo=Synced/Healthy" && break
  sleep 10
done
```
Expected: within the 5-minute poll window, the line shows `app-of-apps=Synced/Healthy podinfo=Synced/Healthy`. If `podinfo` never appears at all, re-check Task 6 Step 1's `exclude: "**/values.yaml"` and the `path: gitops/apps` value — a typo there is the most likely cause. If `podinfo` appears but is `Degraded`, check `kubectl get application podinfo -n argocd -o yaml` for the `status.conditions` message — most likely a `values.yaml` key the podinfo chart doesn't recognize.

- [ ] **Step 4: Commit**

```bash
git add terraform/argocd.tf
git commit -m "Apply the ArgoCD bootstrap Application pointing at the GitHub repo"
```

---

### Task 9: End-to-end verification — podinfo is reachable, and GitOps actually round-trips

**Files:**
- Modify: `terraform/outputs.tf` (append)

**Interfaces:**
- Consumes: `multipass_instance.worker[0].ipv4` (Task 3); `kubectl_manifest.bootstrap_app` (Task 8, transitively — podinfo must be synced for this task's checks to pass).
- Produces: `output.podinfo_url`. Nothing later depends on this programmatically — it's for the human to open in a browser.

- [ ] **Step 1: Append to `terraform/outputs.tf`**

```hcl
output "podinfo_url" {
  value = "http://${multipass_instance.worker[0].ipv4}:30080"
}
```

- [ ] **Step 2: Apply (no infrastructure changes expected, just the new output)**

Run: `terraform -chdir=terraform apply`
Expected: `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` with the new output printed.

- [ ] **Step 3: Confirm podinfo is actually reachable**

Run: `curl -sf "$(terraform -chdir=terraform output -raw podinfo_url)" | grep -qi podinfo && echo REACHABLE`
Expected: prints `REACHABLE`.

- [ ] **Step 4: The actual GitOps proof — change something in git, with zero `terraform apply` or `kubectl apply`, and watch the cluster follow**

Record the current replica count, then edit it in the pushed repo:

```bash
KUBECONFIG=terraform/kubeconfig kubectl get deploy podinfo -n podinfo -o jsonpath='{.spec.replicas}'; echo " <- before"
sed -i '' 's/replicaCount: 2/replicaCount: 3/' gitops/apps/podinfo/values.yaml
git add gitops/apps/podinfo/values.yaml
git commit -m "Bump podinfo replicas to prove GitOps sync"
git push
```

Then poll the cluster — not Terraform, not `kubectl apply`, just watching:

```bash
for i in $(seq 1 30); do
  REPLICAS=$(KUBECONFIG=terraform/kubeconfig kubectl get deploy podinfo -n podinfo -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  echo "replicas: $REPLICAS"
  [ "$REPLICAS" = "3" ] && echo "GITOPS ROUND-TRIP CONFIRMED" && break
  sleep 10
done
```
Expected: within the poll window, `replicas: 3` appears and `GITOPS ROUND-TRIP CONFIRMED` prints, with no `terraform apply` or `kubectl apply` run anywhere in this step. If it never reaches 3, check `kubectl get application podinfo -n argocd -o jsonpath='{.status.sync.status}'` — if it's stuck `OutOfSync`, ArgoCD's default 3-minute polling interval may not have fired yet; it's also safe to force it with `argocd app sync podinfo` if the `argocd` CLI is installed, purely to unblock verification (not part of the normal workflow).

- [ ] **Step 5: Commit the output addition**

```bash
git add terraform/outputs.tf
git commit -m "Add podinfo_url output"
```

(The replica-count change from Step 4 was already committed and pushed as its own commit, separately, as part of proving the round-trip.)

---

### Task 10: `terraform destroy` verification and README

**Files:**
- Create: `README.md`

**Interfaces:** none — this is the terminal task; nothing depends on it.

- [ ] **Step 1: Write `README.md`**

```markdown
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
terraform destroy
```

Removes all VMs (purged immediately, no leftover disk usage) and the
local `terraform/kubeconfig` file. The GitHub repo is untouched — it's
outside Terraform's lifecycle by design.
```

- [ ] **Step 2: Run `terraform destroy` and verify full cleanup**

Run: `terraform -chdir=terraform destroy`
Expected: completes with `Destroy complete! Resources: N destroyed.`

Run: `multipass list`
Expected: no `k3s-server` or `k3s-worker-*` entries at all (not even listed as stopped/deleted — the provider calls `multipass delete --purge`).

Run: `ls terraform/kubeconfig 2>&1`
Expected: `No such file or directory` — confirms the `local_file` resource was cleaned up along with everything else.

- [ ] **Step 3: Re-apply once more to leave the environment in the working state for ongoing use**

Run: `terraform -chdir=terraform apply`
Expected: recreates everything from Task 1–9's steady state; re-run Task 8 Step 3's polling check to confirm `app-of-apps` and `podinfo` both reach `Synced/Healthy` again after a from-scratch rebuild (this is the real regression test — proving the whole pipeline is reproducible, not just that it worked once).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Add README with usage and teardown instructions"
```
