# Podinfo Canary Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make podinfo run as an Argo Rollouts `Rollout` with a canary strategy, so bumping its image tag puts exactly 1 of 3 pods on the new version (behind the existing Service) until manually promoted or aborted.

**Architecture:** Add a new ArgoCD-managed `argo-rollouts` app (controller + CRDs) ahead of podinfo via a sync-wave. Replace podinfo's upstream-Helm-chart `Application` source with hand-authored manifests (the upstream chart only renders a `Deployment`, never a `Rollout`), using Argo Rollouts' "basic" (no-mesh) canary strategy that controls stable/canary ReplicaSet replica counts directly behind one Service.

**Tech Stack:** ArgoCD (Application CRs), Argo Rollouts (Helm chart `argo-rollouts` v2.43.6, CRD `Rollout`), plain Kubernetes manifests (no Helm for podinfo itself), `kubectl-argo-rollouts` CLI plugin for operator commands.

**Spec:** `docs/superpowers/specs/2026-10-08-podinfo-canary-rollout-design.md`

## Layout adjustment vs. the spec (read this first)

The spec's §2/§4 show `rollout.yaml`/`service.yaml` living directly
inside `gitops/apps/podinfo/`, alongside `application.yaml`. While
writing this plan, that turned out to be unsafe: the bootstrap
`app-of-apps` Application recurses **all** of `gitops/apps/**`
(`directory: { recurse: true, exclude: "**/values.yaml" }` in
`gitops/bootstrap/app-of-apps.yaml`). If podinfo's `Rollout`/`Service`
manifests also lived under `gitops/apps/podinfo/`, app-of-apps would
apply them *again* as top-level resources — two different ArgoCD
Applications (`app-of-apps` and `podinfo`) both claiming ownership of
the same `Rollout`/`Service`, which ArgoCD will fight over
(`OutOfSync` ping-pong).

Fixing this by editing `gitops/bootstrap/app-of-apps.yaml`'s `exclude`
pattern was rejected: that file is Terraform-templated and applied
directly by `kubectl_manifest.bootstrap_app` (not ArgoCD-synced), so
changing it would require a `terraform apply` — contradicting the
spec's explicit "no Terraform changes" success criterion.

**Resolution:** workload manifests go in a new top-level
`gitops/manifests/podinfo/` directory, *outside* the `gitops/apps/`
tree app-of-apps recurses. `gitops/apps/podinfo/application.yaml`
(still recursed/applied by app-of-apps, unchanged mechanism from
today) now points its own `source.path` at `gitops/manifests/podinfo`.
No architectural decision from the spec changes — install mechanism,
canary strategy, sync-wave ordering, and manual promote/abort are all
exactly as approved. Only the concrete file paths differ from the
spec's illustrative layout.

```
gitops/
├── bootstrap/
│   └── app-of-apps.yaml                 # UNCHANGED
├── apps/                                 # recursed by app-of-apps — Application CRs only
│   ├── argo-rollouts/
│   │   └── application.yaml              # NEW
│   └── podinfo/
│       ├── application.yaml              # CHANGED: source -> gitops/manifests/podinfo
│       └── values.yaml                   # DELETED
└── manifests/                             # NOT recursed by app-of-apps
    └── podinfo/
        ├── rollout.yaml                   # NEW
        └── service.yaml                   # NEW
```

## Global Constraints

- Always run `terraform apply`/`destroy` with `-parallelism=1` (this
  repo's hard rule — concurrent Multipass VM launches race on IP
  assignment).
- No files under `terraform/` change for this feature. Everything is a
  `gitops/` edit, consistent with "Terraform's job ends at ArgoCD
  running; ArgoCD owns everything under `gitops/apps/`."
- `argo-rollouts` Helm chart pinned to `2.43.6` (confirmed latest
  stable on `argoproj/argo-helm` main branch as of 2026-10-08). Do not
  downgrade without explicit approval, per Vijay's standing dependency
  rule.
- Canary strategy is exactly `steps: [{setWeight: 33}, {pause: {}}]` —
  no `trafficRouting` plugin, no timed/auto-promotion. Promotion is
  always a manual `kubectl argo-rollouts promote|abort` command.
- Podinfo's workload manifests (`Rollout`, `Service`) must never live
  under any path `gitops/bootstrap/app-of-apps.yaml` recurses
  (`gitops/apps/**`) — see the layout adjustment above. This is a hard
  constraint for every task that adds or moves a file in `gitops/`.

## Review Focus

- CRD-not-yet-installed race on a from-scratch bootstrap: does the
  `argo-rollouts` Application's sync-wave actually make the `Rollout`
  CRD exist before ArgoCD evaluates podinfo's Application, or does
  podinfo transiently fail with "no matches for kind Rollout"? (Task 6)
- `kubectl argo-rollouts abort` only patches the live `Rollout`'s
  `status`, not git — with `selfHeal: true` on podinfo's Application,
  does the rollback actually stick, or does it need a git revert to be
  durable? A reasonable person running `abort` would expect it to
  "undo" the canary; if it silently doesn't, that's a surprise worth
  documenting precisely. (Task 6, Task 5 README caveat)
- Canary pod stuck `Progressing` forever instead of reaching the
  paused 2/1 split, because the hand-authored `Rollout`'s
  liveness/readiness probe path or port doesn't match podinfo's actual
  `/healthz`/`/readyz` endpoints (no chart default to fall back on
  anymore, unlike before). (Task 6)
- Leftover `sources:`/`ref: values` wiring in podinfo's `Application`
  spec after dropping the Helm chart source — ArgoCD would reject or
  mis-sync an Application whose spec still references a `$values` ref
  source that no longer resolves to anything. (Task 2)
- `gitops/manifests/podinfo/**` accidentally ending up inside a path
  `app-of-apps` recurses, causing duplicate resource ownership between
  `app-of-apps` and `podinfo`'s own Application. (Task 1, Task 3,
  Task 4 — directory placement; Task 6 — confirmed live via no
  `OutOfSync`/ownership-conflict errors)

---

### Task 1: Add the `argo-rollouts` ArgoCD Application

**Files:**
- Create: `gitops/apps/argo-rollouts/application.yaml`

**Interfaces:**
- Produces: an ArgoCD `Application` named `argo-rollouts` that installs
  the Argo Rollouts controller + CRDs into namespace `argo-rollouts`,
  annotated `argocd.argoproj.io/sync-wave: "-1"` so it syncs ahead of
  podinfo. Task 6 depends on this app reaching `Synced`/`Healthy`
  before podinfo's `Rollout` manifest can be accepted by the API
  server.

- [ ] **Step 1: Write the validation check (fails — file doesn't exist yet)**

```bash
test "$(yq eval '.kind' gitops/apps/argo-rollouts/application.yaml)" = "Application" && \
test "$(yq eval '.spec.source.chart' gitops/apps/argo-rollouts/application.yaml)" = "argo-rollouts" && \
test "$(yq eval '.spec.source.repoURL' gitops/apps/argo-rollouts/application.yaml)" = "https://argoproj.github.io/argo-helm" && \
test "$(yq eval '.spec.source.targetRevision' gitops/apps/argo-rollouts/application.yaml)" = "2.43.6" && \
test "$(yq eval '.spec.destination.namespace' gitops/apps/argo-rollouts/application.yaml)" = "argo-rollouts" && \
test "$(yq eval '.metadata.annotations."argocd.argoproj.io/sync-wave"' gitops/apps/argo-rollouts/application.yaml)" = "-1" && \
echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: the command above from the repo root.
Expected: `yq` errors with something like `Error: open gitops/apps/argo-rollouts/application.yaml: no such file or directory` — no `PASS` printed.

- [ ] **Step 3: Create the file**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.43.6
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

(Relies on the chart's default `installCRDs: true` — no explicit
`helm.values` override needed.)

- [ ] **Step 4: Run the validation check again to verify it passes**

Run: the same command as Step 1.
Expected: `PASS` printed, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add gitops/apps/argo-rollouts/application.yaml
git commit -m "Add ArgoCD Application for Argo Rollouts controller"
```

---

### Task 2: Point podinfo's Application at plain manifests instead of the Helm chart

**Files:**
- Modify: `gitops/apps/podinfo/application.yaml`
- Delete: `gitops/apps/podinfo/values.yaml`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: podinfo's ArgoCD `Application` now syncs from
  `gitops/manifests/podinfo` (this repo, same `repoURL`/
  `targetRevision` as before). Task 3 and Task 4 create the files that
  path must contain before this Application can go `Healthy`.

- [ ] **Step 1: Write the validation check (fails — old content still in place)**

```bash
test "$(yq eval '.spec.source.path' gitops/apps/podinfo/application.yaml)" = "gitops/manifests/podinfo" && \
test "$(yq eval '.spec.source.repoURL' gitops/apps/podinfo/application.yaml)" = "https://github.com/vbvj4u/tf-kube-mp.git" && \
test "$(yq eval '.spec.sources' gitops/apps/podinfo/application.yaml)" = "null" && \
test ! -f gitops/apps/podinfo/values.yaml && \
echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: the command above from the repo root.
Expected: first `test` fails (current `spec.source.path` doesn't exist
— today's file uses `spec.sources`, a list, not `spec.source`), so no
`PASS` printed.

- [ ] **Step 3: Replace `application.yaml`'s contents**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/vbvj4u/tf-kube-mp.git
    targetRevision: main
    path: gitops/manifests/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Delete the now-unused values file**

```bash
rm gitops/apps/podinfo/values.yaml
```

- [ ] **Step 5: Run the validation check again to verify it passes**

Run: the same command as Step 1.
Expected: `PASS` printed, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add gitops/apps/podinfo/application.yaml
git rm gitops/apps/podinfo/values.yaml
git commit -m "Point podinfo Application at plain manifests instead of upstream Helm chart"
```

---

### Task 3: Add podinfo's `Rollout` manifest

**Files:**
- Create: `gitops/manifests/podinfo/rollout.yaml`

**Interfaces:**
- Consumes: the `Rollout` CRD installed by Task 1's `argo-rollouts`
  Application (only needed live, not for this task's static check).
- Produces: a `Rollout` named `podinfo` in namespace `podinfo`, pod
  labels `app: podinfo`, which Task 4's `Service` selects on.

- [ ] **Step 1: Write the validation check (fails — file doesn't exist yet)**

```bash
test "$(yq eval '.kind' gitops/manifests/podinfo/rollout.yaml)" = "Rollout" && \
test "$(yq eval '.metadata.namespace' gitops/manifests/podinfo/rollout.yaml)" = "podinfo" && \
test "$(yq eval '.spec.replicas' gitops/manifests/podinfo/rollout.yaml)" = "3" && \
test "$(yq eval '.spec.selector.matchLabels.app' gitops/manifests/podinfo/rollout.yaml)" = "podinfo" && \
test "$(yq eval '.spec.template.metadata.labels.app' gitops/manifests/podinfo/rollout.yaml)" = "podinfo" && \
test "$(yq eval '.spec.template.spec.containers[0].image' gitops/manifests/podinfo/rollout.yaml)" = "ghcr.io/stefanprodan/podinfo:6.15.0" && \
test "$(yq eval '.spec.template.spec.containers[0].resources.requests.cpu' gitops/manifests/podinfo/rollout.yaml)" = "50m" && \
test "$(yq eval '.spec.template.spec.containers[0].resources.limits.memory' gitops/manifests/podinfo/rollout.yaml)" = "128Mi" && \
test "$(yq eval '.spec.strategy.canary.steps[0].setWeight' gitops/manifests/podinfo/rollout.yaml)" = "33" && \
test "$(yq eval '.spec.strategy.canary.steps[1] | has("pause")' gitops/manifests/podinfo/rollout.yaml)" = "true" && \
echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: the command above from the repo root.
Expected: `yq` errors with "no such file or directory" — no `PASS`.

- [ ] **Step 3: Create the file**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: podinfo
  namespace: podinfo
  labels:
    app: podinfo
spec:
  replicas: 3
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.15.0
          ports:
            - name: http
              containerPort: 9898
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
  strategy:
    canary:
      steps:
        - setWeight: 33
        - pause: {}
```

(Resource requests/limits and `replicas: 3` carry forward today's
`values.yaml` values exactly — only the image tag is new, pinned
explicitly since raw manifests have no chart `appVersion` default to
fall back on.)

- [ ] **Step 4: Run the validation check again to verify it passes**

Run: the same command as Step 1.
Expected: `PASS` printed, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add gitops/manifests/podinfo/rollout.yaml
git commit -m "Add podinfo Rollout with basic canary strategy"
```

---

### Task 4: Add podinfo's `Service` manifest

**Files:**
- Create: `gitops/manifests/podinfo/service.yaml`

**Interfaces:**
- Consumes: pod labels `app: podinfo` produced by Task 3's `Rollout`.
- Produces: a `NodePort` Service named `podinfo` in namespace
  `podinfo`, port `9898`, `nodePort: 30080` — identical external
  behavior to today's chart-rendered Service (same `terraform output
  podinfo_url` keeps working unchanged).

- [ ] **Step 1: Write the validation check (fails — file doesn't exist yet)**

```bash
test "$(yq eval '.kind' gitops/manifests/podinfo/service.yaml)" = "Service" && \
test "$(yq eval '.metadata.namespace' gitops/manifests/podinfo/service.yaml)" = "podinfo" && \
test "$(yq eval '.spec.type' gitops/manifests/podinfo/service.yaml)" = "NodePort" && \
test "$(yq eval '.spec.selector.app' gitops/manifests/podinfo/service.yaml)" = "podinfo" && \
test "$(yq eval '.spec.ports[0].port' gitops/manifests/podinfo/service.yaml)" = "9898" && \
test "$(yq eval '.spec.ports[0].nodePort' gitops/manifests/podinfo/service.yaml)" = "30080" && \
echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: the command above from the repo root.
Expected: `yq` errors with "no such file or directory" — no `PASS`.

- [ ] **Step 3: Create the file**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: podinfo
  labels:
    app: podinfo
spec:
  type: NodePort
  selector:
    app: podinfo
  ports:
    - name: http
      port: 9898
      targetPort: http
      nodePort: 30080
```

- [ ] **Step 4: Run the validation check again to verify it passes**

Run: the same command as Step 1.
Expected: `PASS` printed, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add gitops/manifests/podinfo/service.yaml
git commit -m "Add podinfo Service for the Rollout-managed pods"
```

---

### Task 5: Document the canary workflow in the README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the `promote`/`abort` commands and the abort/selfHeal
  caveat validated live in Task 6 — this task writes the documentation,
  Task 6 proves it's accurate.
- Produces: operator-facing instructions; nothing later depends on this
  programmatically.

- [ ] **Step 1: Write the validation check (fails — section doesn't exist yet)**

```bash
grep -q "^## Canary deployments" README.md && \
grep -q "kubectl-argo-rollouts" README.md && \
grep -q "abort.*is transient" README.md && \
echo PASS
```

- [ ] **Step 2: Run it to verify it fails**

Run: the command above from the repo root.
Expected: no `PASS` (grep finds nothing, exits non-zero).

- [ ] **Step 3: Replace the stale podinfo troubleshooting bullet**

In `README.md`, find this existing bullet under `## Troubleshooting`:

```markdown
- **`podinfo` Application stuck `OutOfSync`/`Degraded`**: check
  `kubectl get application podinfo -n argocd -o yaml` for
  `status.conditions` — most likely a `values.yaml` key the podinfo
  chart doesn't recognize.
```

Replace it with:

```markdown
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
```

- [ ] **Step 4: Add a new "Canary deployments" section**

Insert this new section after `## Troubleshooting` and before
`## Teardown`:

```markdown
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
```

- [ ] **Step 5: Run the validation check again to verify it passes**

Run: the same command as Step 1.
Expected: `PASS` printed, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "Document the podinfo canary workflow and its abort/selfHeal caveat"
```

---

### Task 6: Stand up the cluster and validate the full canary cycle live

**Files:** none created/modified — this task only runs commands and,
as part of exercising the workflow, makes two throwaway git commits
(image-tag bump, then revert) to `gitops/manifests/podinfo/rollout.yaml`.

**Interfaces:**
- Consumes: Tasks 1–5's committed manifests and docs.
- Produces: a verified end-to-end proof that the design in the spec
  (§1 success criteria) actually holds on a real cluster.

- [ ] **Step 1: Confirm the CLI plugin is installed**

```bash
kubectl argo-rollouts version
```

Expected: prints a client (and, once connected, server) version. If
missing: `brew install argoproj/tap/kubectl-argo-rollouts`.

- [ ] **Step 2: Bring up the cluster**

```bash
cd terraform
terraform apply -parallelism=1
```

Expected: completes with no errors (full provisioning run — budget
several minutes for VM boot + cloud-init + ArgoCD install).

- [ ] **Step 3: Confirm both ArgoCD Applications reach Healthy**

```bash
KUBECONFIG=terraform/kubeconfig kubectl get applications -n argocd
```

Expected: `app-of-apps`, `argo-rollouts`, and `podinfo` all show
`Synced`/`Healthy`. If `podinfo` is transiently `Degraded` with "no
matches for kind Rollout" right after apply, re-run the command after
~30s — this is the CRD race called out in Review Focus, and it should
self-resolve once `argo-rollouts` finishes syncing (confirms the
sync-wave ordering works without manual intervention).

- [ ] **Step 4: Confirm the baseline stable state**

```bash
KUBECONFIG=terraform/kubeconfig kubectl get pods -n podinfo -o wide
KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts get rollout podinfo -n podinfo
```

Expected: 3/3 pods `Running`/`Ready`, all on `6.15.0`; rollout status
`Healthy` with a single stable ReplicaSet at full weight.

- [ ] **Step 5: Trigger a canary (throwaway validation bump)**

```bash
cd ..
sed -i '' 's/podinfo:6.15.0/podinfo:6.14.1/' gitops/manifests/podinfo/rollout.yaml
git add gitops/manifests/podinfo/rollout.yaml
git commit -m "Validation: bump podinfo to 6.14.1 to exercise the canary split"
git push
```

(`6.14.1` is simply the prior real release — used here only to prove
the mechanism with two genuinely different, pullable image tags. It
gets reverted in Step 8.)

- [ ] **Step 6: Watch it reach the paused canary split**

```bash
KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts get rollout podinfo -n podinfo --watch
```

Expected: within one ArgoCD sync interval, shows `Paused`, 2 pods on
`6.15.0` (stable) + 1 pod on `6.14.1` (canary). Ctrl-C once stable.

If instead it stays `Progressing` and the canary pod never turns
`Ready`: check `kubectl describe pod -n podinfo <canary-pod>` for a
failing liveness/readiness probe — this is the probe-path/port
mismatch risk called out in Review Focus.

- [ ] **Step 7: Confirm the traffic split for real**

```bash
PODINFO_URL=$(terraform -chdir=terraform output -raw podinfo_url)
for i in $(seq 1 15); do curl -s "$PODINFO_URL/version"; echo; done | sort | uniq -c
```

Expected: roughly 1 in 3 lines show `6.14.1`, the rest `6.15.0`.

- [ ] **Step 8: Promote, then revert back to a clean baseline**

```bash
KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts promote podinfo -n podinfo
KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts get rollout podinfo -n podinfo
```

Expected: fully promotes to 3/3 on `6.14.1`.

```bash
git revert --no-edit HEAD
git push
```

Expected: ArgoCD's `selfHeal` syncs the revert automatically; within
one sync interval, `kubectl get pods -n podinfo` shows 3/3 back on
`6.15.0` with no manual `kubectl` intervention — confirming a git
revert is the durable way back to baseline.

- [ ] **Step 9: Verify the abort-vs-selfHeal caveat directly**

```bash
sed -i '' 's/podinfo:6.15.0/podinfo:6.14.1/' gitops/manifests/podinfo/rollout.yaml
git add gitops/manifests/podinfo/rollout.yaml
git commit -m "Validation: bump podinfo to 6.14.1 again, to verify abort behavior"
git push
# wait for it to reach Paused (as in Step 6), then:
KUBECONFIG=terraform/kubeconfig kubectl argo-rollouts abort podinfo -n podinfo
KUBECONFIG=terraform/kubeconfig kubectl get pods -n podinfo -o wide
```

Expected: immediately after `abort`, pods return to 3/3 on `6.15.0`
(stable) — but since the committed manifest still says `6.14.1`,
`kubectl argo-rollouts get rollout podinfo -n podinfo` (check a minute
or two later) is expected to show the controller attempting the
rollout again, because `abort` never changed what git/ArgoCD consider
the desired state. Record whichever behavior is actually observed —
this is the exact caveat Task 5's README section documents, and this
step is what confirms that documentation is accurate rather than
assumed.

Then clean up back to baseline the durable way:

```bash
git revert --no-edit HEAD
git push
```

Expected: 3/3 on `6.15.0` again, confirmed via `kubectl get pods -n
podinfo`.

- [ ] **Step 10: Final state check**

```bash
KUBECONFIG=terraform/kubeconfig kubectl get applications -n argocd
KUBECONFIG=terraform/kubeconfig kubectl get pods -n podinfo -o wide
git log --oneline -6
```

Expected: both Applications `Synced`/`Healthy`, 3/3 pods on `6.15.0`,
and git history shows the two bump commits each followed by their
revert — repo and cluster end this task in a clean, fully-stable
state. (The cluster itself is left running; `terraform destroy
-parallelism=1` is available whenever you're done with it, per the
README's Teardown section — not run automatically as part of this
task.)
