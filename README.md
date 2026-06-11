# preview-staging-prod-example

A self-contained app repository that demonstrates a complete GitOps workflow with Flux Operator: per-PR preview environments, a staging environment tracking `main`, and a production environment tracking the `production` branch. Each environment gets its own (stubbed) Neon Postgres branch.

This directory is meant to be **copy-pasted into a fresh GitHub repository**. Once the example repo exists on GitHub, you wire your local k3d cluster (see the parent project) to reconcile it.

## Repository layout

```
.
├── Dockerfile                 # alpine + busybox httpd
├── app/server.sh              # the stub app
├── .github/
│   ├── actions/stub-neon-provision/   # composite action; emits fake DSN
│   └── workflows/             # pr.yml, staging.yml, production.yml
├── deploy/                    # Kustomize tree (base + overlays)
└── flux/                      # Flux CRs (sources, image automation, previews)
```

## Cluster prerequisites

Your local k3d cluster (the parent project) must run a `FluxInstance` that includes the image-automation controllers. The parent project's `charts/flux-instance.yml` already does this.

## First-run setup on GitHub

After you push this directory to a new GitHub repo and the first workflow run completes:

1. **Make the GHCR package public** (so the cluster can pull without an image-pull secret).
   - Visit `https://github.com/users/<owner>/packages/container/<repo>/settings`
     (or `/orgs/<owner>/packages/container/<repo>/settings` for orgs).
   - *Danger Zone* → *Change package visibility* → **Public**.
2. **Link the GHCR package to the repo with Write access**.
   - Same settings page → *Manage Actions access* → *Add repository* → pick this repo → role: **Write**.
3. **Create a `preview` label on the repo** — used by `ResourceSetInputProvider` to gate which PRs spawn preview envs.
   - Issues/PRs → Labels → New label → name: `preview`.
4. **Create the `production` branch** off `main`.
   ```sh
   git push origin main:production
   ```
   Without this branch, `production.yml` and `ImageUpdateAutomation app-production` cannot do anything.

5. **Replace placeholders** in the YAML files under `deploy/` and `flux/`. Two forms get substituted:
   - `OWNER/REPO` → your GitHub owner/repo (used in image refs and Git URLs).
   - `OWNER-REPO` → the same value with a dash instead of a slash (used as a Kubernetes namespace prefix; slashes aren't valid in namespace names).

   Run from the repo root:
   ```sh
   OWNER_REPO_SLASH="<your-owner>/<your-repo>"           # e.g. acme/myapp
   OWNER_REPO_DASH="${OWNER_REPO_SLASH//\//-}"          # e.g. acme-myapp
   grep -rl 'OWNER/REPO'  deploy flux | xargs sed -i "s|OWNER/REPO|${OWNER_REPO_SLASH}|g"
   grep -rl 'OWNER-REPO'  deploy flux | xargs sed -i "s|OWNER-REPO|${OWNER_REPO_DASH}|g"
   ```

## Wiring Flux to this repo

Run from your k3d cluster's kubeconfig:

One PAT, one Secret — used by `GitRepository` (read + `ImageUpdateAutomation` push) **and** `ResourceSetInputProvider` (read PRs). Use a fine-grained PAT scoped to this single repo with:

- Repository permissions → **Contents: Read and write**
- Repository permissions → **Pull requests: Read**

```sh
# 1. Create the shared Git auth Secret.
kubectl -n flux-system create secret generic flux-git-auth \
  --from-literal=username=git \
  --from-literal=password=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# 2. Point Flux at this repo and start reconciling.
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: { name: app, namespace: flux-system }
spec:
  url: https://github.com/<your-owner>/<your-repo>
  secretRef: { name: flux-git-auth }
  ref: { branch: main }
  interval: 1m
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: app-bootstrap, namespace: flux-system }
spec:
  sourceRef: { kind: GitRepository, name: app }
  path: ./flux
  prune: true
  interval: 1m
EOF
```

After this, the bootstrap `Kustomization` discovers `flux/source.yaml`, `flux/image/*`, `flux/kustomizations/*`, and `flux/previews/*` and takes over. You can delete `app-bootstrap` once `flux/source.yaml` is reconciled; Flux is self-managing from that point on.

## End-to-end flow

- **Open a PR labeled `preview`** — `pr.yml` builds and pushes `ghcr.io/<owner>/<repo>:pr-<N>-<sha>`. `ResourceSetInputProvider` sees the labeled PR; `ResourceSet` materializes a namespace `<owner>-<repo>-pr-<N>`, a `ConfigMap`, and a per-PR `Kustomization` that deploys the app at `pr-<N>.preview.local.domain`. Update the PR head → new image, ResourceSet redeploys. Close the PR or remove the label → ResourceSet prunes everything.
- **Push to `main`** — `staging.yml` builds `:main-<run>-<ts>`. `ImagePolicy app-staging` extracts the run number, picks the highest. `ImageUpdateAutomation app-staging` rewrites the staging overlay's image tag and commits back as `fluxcdbot`. `Kustomization app-staging` reconciles into the `<owner>-<repo>-app-staging` namespace.
- **Push to `production`** — same pattern with `:production-<run>-<ts>` and the production overlay/branch (namespace `<owner>-<repo>-app-production`).

## Verifying

```sh
kubectl -n flux-system get gitrepository app
kubectl -n flux-system get imagerepository app
kubectl -n flux-system get imagepolicy
kubectl -n flux-system get imageupdateautomation
kubectl -n flux-system get kustomization
kubectl -n flux-system get resourcesetinputprovider app-prs -o yaml | yq '.status'
kubectl -n flux-system get resourceset app-previews -o yaml | yq '.status'
kubectl get ns | grep -- "-app-staging\|-app-production\|-pr-"
kubectl -n <owner>-<repo>-app-staging get pods,svc,ingress
```

## Teardown

```sh
kubectl -n flux-system delete kustomization app-bootstrap   # tears down everything reconciled from flux/
kubectl -n flux-system delete secret flux-git-auth
```

## Deliberately out of scope

- Real Neon API calls — see `.github/actions/stub-neon-provision/action.yml` for the replacement point.
- Real secrets management — `deploy/base/secret.yaml` is a plain `Secret`. Swap for SOPS / SealedSecrets / ExternalSecrets+AWS SM in real use.
- TLS / cert-manager / DNS for `local.domain`. Add `/etc/hosts` entries pointing at your k3d ingress IP if you want to hit the ingresses from a browser.
- Image pull secrets — assumes GHCR package is public.
- Cluster-side authentication on the Flux UI or the app.

## Going further

See `HANDOFF-CROSSPLANE.md` for a sketch of how to move the create/teardown of external resources (Neon branches, S3 buckets, etc.) off CI and onto Flux+Crossplane.
