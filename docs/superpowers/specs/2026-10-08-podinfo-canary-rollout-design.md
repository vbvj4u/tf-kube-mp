# Podinfo Canary Rollout via Argo Rollouts — Design Spec

- **Date**: 2026-10-08
- **Status**: Approved (design), pending implementation plan
- **Owner**: Vijay

## 1. Intent

Demonstrate a real canary deployment against the existing podinfo app:
when a new version is rolled out, exactly 1 of the 3 podinfo pods runs
the new version while the other 2 keep serving the old one, so hitting
the app repeatedly shows the difference on roughly 1 in 3 requests. The
rollout pauses there until explicitly promoted or aborted.

This is purely a GitOps-side change — no Terraform changes, no new
cluster bootstrap steps. Everything here lives under `gitops/apps/` and
is reconciled by ArgoCD, consistent with this repo's existing principle
that Terraform's job ends at "ArgoCD is running"; ArgoCD owns everything
under `gitops/apps/` from then on.

### Success criteria

- A new ArgoCD-managed `argo-rollouts` app installs the Argo Rollouts
  controller + CRDs with no Terraform involvement.
- Podinfo is managed by a `Rollout` resource (not a `Deployment`), with
  `replicas: 3` and a canary strategy that steps to `setWeight: 33` then
  pauses indefinitely.
- Bumping podinfo's image tag and pushing to git results in exactly 2
  stable pods + 1 canary pod running, reachable through the existing
  Service/NodePort with no mesh or ingress controller involved.
- `kubectl argo-rollouts promote podinfo -n podinfo` completes the
  rollout to 100% new version; `kubectl argo-rollouts abort podinfo -n
  podinfo` rolls back to the old version — both exercised once as part
  of validation.

## 2. Architecture overview

```
gitops/apps/
  argo-rollouts/
    application.yaml      -- ArgoCD Application, sync-wave "-1"
                              installs argo-rollouts Helm chart
                              (argoproj.github.io/argo-helm,
                              chart "argo-rollouts") into the
                              argo-rollouts namespace
  podinfo/
    application.yaml      -- ArgoCD Application, now points at a
                              directory of plain manifests in this
                              repo instead of the upstream podinfo
                              Helm chart
    rollout.yaml           -- kind: Rollout (argoproj.io/v1alpha1),
                              replicas: 3, canary strategy
    service.yaml            -- kind: Service, NodePort 30080,
                              selector matches Rollout pod labels
                              (unchanged behavior from today)
```

Key principle (unchanged from the base design): Terraform applies
exactly one bootstrap `Application`; everything under `gitops/apps/` —
including this new `argo-rollouts` app — is reconciled by ArgoCD from
git. Terraform is not touched by this change at all.

Sequencing: the `argo-rollouts` Application carries
`argocd.argoproj.io/sync-wave: "-1"` so ArgoCD applies/heals it ahead of
`podinfo`, since podinfo's `Rollout` manifest requires the `Rollout` CRD
to already exist in the cluster.

## 3. Key decisions and rejected alternatives

| Decision | Chosen | Rejected alternative(s) | Why |
|---|---|---|---|
| Install mechanism for Argo Rollouts | New ArgoCD `Application` under `gitops/apps/` | Terraform `helm_release`, alongside ArgoCD's own install | Matches this repo's existing principle that Terraform's job ends at "ArgoCD is running"; everything else is GitOps-managed. No `terraform/*.tf` changes needed. |
| Traffic-splitting mechanism | Argo Rollouts "basic canary" (replica-count ratio, no `trafficRouting` plugin) | Add NGINX Ingress or a service mesh for exact weighted splitting | Podinfo today has no ingress/mesh in front of it (plain NodePort `Service`). Adding one purely for traffic-splitting is a second new subsystem on top of Argo Rollouts itself — disproportionate for a 3-node Multipass demo cluster. Basic canary needs zero additional infra and meets the actual goal ("1 pod different from the other 2"). |
| Podinfo manifest source | Plain manifests (`Rollout` + `Service`) authored in this repo | Keep the upstream podinfo Helm chart | Confirmed by reading the upstream chart's `templates/deployment.yaml`: it only ever renders `kind: Deployment`, with no option to emit a `Rollout`. Argo Rollouts requires the resource itself to be `kind: Rollout`, so the chart can't be reused for this; manifests are hand-authored instead, carrying forward the same image/resources/replica values that live in today's `values.yaml`. |
| What differs on the canary pod | Podinfo image tag/version bump | Same image, different `ui.color`/`ui.message` only | Exercises the realistic case canary deployments exist for (validate a new version on live traffic before full rollout). Podinfo's `/version` endpoint and UI both already surface the running version with no extra config. |
| Canary step/pause behavior | `setWeight: 33` then `pause: {}` (indefinite, manual promote/abort) | Timed auto-promotion after a fixed duration | Gives a controllable window to actually observe the 2-stable/1-canary split and inspect it before deciding to promote or abort — appropriate for a demo/learning setup rather than a production auto-promote pipeline. |
| CRD/controller sequencing | `argocd.argoproj.io/sync-wave: "-1"` on the `argo-rollouts` Application | Rely on ArgoCD's default sync retries to eventually succeed once the CRD appears | Deterministic rather than racy; avoids a confusing transient "Rollout CRD not found" failure on podinfo's Application during first bootstrap. |

## 4. Repo & module layout (additions/changes only)

```
gitops/
└── apps/
    ├── argo-rollouts/                 # NEW
    │   └── application.yaml
    └── podinfo/
        ├── application.yaml           # CHANGED: Helm source -> directory source
        ├── values.yaml                # REMOVED (no longer a Helm release)
        ├── rollout.yaml                # NEW
        └── service.yaml                 # NEW
```

No files under `terraform/` change.

## 5. Manifest details

**`gitops/apps/argo-rollouts/application.yaml`**: ArgoCD `Application`,
`source.chart: argo-rollouts`, `source.repoURL:
https://argoproj.github.io/argo-helm`, `targetRevision` pinned to the
latest stable chart version at implementation time (confirmed `2.43.5`
as of 2026-10-08 — re-check the registry if this is picked up later, per
this repo's standing dependency rule), `destination.namespace:
argo-rollouts`, `syncPolicy.automated.selfHeal: true`,
`syncOptions: [CreateNamespace=true]`, annotated with
`argocd.argoproj.io/sync-wave: "-1"`.

**`gitops/apps/podinfo/application.yaml`**: same `destination.namespace:
podinfo` as today, but `source` becomes a single git source
(`repoURL`/`targetRevision` = this repo, `path: gitops/apps/podinfo`)
instead of the two-source upstream-chart-plus-values-ref setup. No
sync-wave needed (defaults to after wave `-1`).

**`gitops/apps/podinfo/rollout.yaml`**: `kind: Rollout`, carries forward
today's `values.yaml` settings directly (`replicas: 3`, the same
resource requests/limits: `50m`/`64Mi` requests, `100m`/`128Mi` limits).
Today's Helm-based setup never pins an explicit image tag — it floats
on the chart's default `appVersion` — but raw manifests have no such
default, so implementation must pin an explicit `image: 
ghcr.io/stefanprodan/podinfo:<tag>` as the new "stable" baseline (the
chart's current default `appVersion` at implementation time is the
natural choice, so behavior doesn't silently change on cutover). That
pinned tag is what gets bumped to produce a canary. Adds:

```yaml
spec:
  strategy:
    canary:
      steps:
        - setWeight: 33
        - pause: {}
```

**`gitops/apps/podinfo/service.yaml`**: `kind: Service`, `type:
NodePort`, `nodePort: 30080` (unchanged), selector matches the common
pod labels on the Rollout's `template.metadata.labels` (not the
`rollouts-pod-template-hash` label Argo Rollouts injects per-ReplicaSet)
so the Service's endpoints naturally include both the stable and canary
ReplicaSets' pods.

## 6. Error handling & edge cases

- **CRD not yet installed when podinfo syncs**: mitigated by the
  sync-wave ordering (§2, §3). If it still races on a from-scratch
  bootstrap, it surfaces as podinfo's Application being `Degraded` with
  a clear "no matches for kind Rollout" error in the ArgoCD UI/CLI, and
  resolves itself on ArgoCD's next automatic reconciliation once
  `argo-rollouts` finishes syncing — not a silent or permanent failure.
- **Uneven split from rounding**: `setWeight: 33` against `replicas: 3`
  resolves to exactly 1 canary / 2 stable (Argo Rollouts rounds up for
  the canary count), so no ambiguity at this specific replica count.
- **Forgetting to promote/abort**: the indefinite `pause: {}` means a
  canary left unattended stays at 2/1 split forever — this is intended
  behavior for a demo, not treated as an error state. `kubectl
  argo-rollouts get rollout podinfo -n podinfo` shows the paused state
  clearly.
- **`kubectl-argo-rollouts` CLI missing locally**: promote/abort/get
  commands require this plugin (`brew install
  argoproj/tap/kubectl-argo-rollouts`); called out in the README rather
  than scripted, since nothing else in this repo needs a kubectl plugin
  today.
- **`terraform destroy`**: unaffected — the whole cluster (including
  `argo-rollouts` and the `Rollout` resource) is torn down with the VMs,
  same as today's podinfo teardown.

## 7. Testing / validation plan

1. `terraform apply` (no changes expected here) followed by `kubectl get
   applications -n argocd` — expect `app-of-apps`, `argo-rollouts`, and
   `podinfo` all `Synced`/`Healthy`.
2. `kubectl get pods -n podinfo` — expect 3/3 Ready, all on the original
   image tag, `kubectl argo-rollouts get rollout podinfo -n podinfo`
   shows a single stable ReplicaSet at full weight.
3. Bump the image tag in `rollout.yaml`, push. Watch `kubectl
   argo-rollouts get rollout podinfo -n podinfo --watch` until it shows
   `Paused` with 2 stable / 1 canary pods.
4. Hit the NodePort URL (or `/version`) repeatedly from the Mac browser
   or `curl` in a loop — confirm roughly 1 in 3 responses show the new
   version.
5. `kubectl argo-rollouts promote podinfo -n podinfo` — confirm it
   finishes to 3/3 on the new version.
6. Repeat steps 3–4 once more, this time run `kubectl argo-rollouts
   abort podinfo -n podinfo` instead — confirm it rolls back to 3/3 on
   the old version.

## 8. Out of scope (for this spec)

- Exact weighted traffic splitting via a service mesh or ingress
  controller (see §3 — explicitly rejected for this pass).
- Automated analysis/metrics-based promotion (Flagger-style); promotion
  here is always manual.
- Applying this pattern to any app other than podinfo.
- Multi-step canaries with more than one intermediate weight.
