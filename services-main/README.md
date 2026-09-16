# services/

One folder per deployable service. Each service is self-contained — docs, Bicep params, Helm values, custom charts, and operational scripts all live together.

## Currently here

| Service | Status |
|---|---|
| [code-marketplace/](./code-marketplace/) | Scaffolded — not yet deployed. VS Code Marketplace gallery for Gov Cloud, Artifactory-backed. |

Services still in the legacy `services-status/` layout (artifactory, jira, confluence, gitlab, rocketchat, cameo, argocd) will migrate here one at a time as they're worked on. See `../services-status/README.md` for the canonical service pipeline status.

## Per-service folder shape

```
services/<name>/
├── README.md                       Service front door — quick reference, file index, status
├── <name>.md                       Step-by-step deploy guide
├── worklog.md                      Per-service daily notes (optional)
├── .gitignore                      Service-scoped ignores
│
├── service.json                    Chart name, namespace, secret list
├── service.conf                    Env config consumed by deploy.sh
├── values.yaml                     Helm values template (envsubst'd at deploy)
│
├── params.dev.bicepparam           Bicep params — one per environment
├── params.dev-airgap.bicepparam
├── params.prod.bicepparam
│
├── images.txt                      Container images to mirror to Gov ACR
├── charts.txt                      Upstream Helm charts to mirror to Gov ACR (optional)
│
├── scripts/                        Service ops: deploy, backup, restore, status, etc.
├── charts/                         Custom in-repo Helm charts (NOT upstream)
├── extensions/  /  cache/          Service-specific local caches (gitignored)
├── manifests/                      Raw K8s YAML for non-Helm resources (optional)
└── cloud-init/                     VM bootstrap (only services with VMs, e.g. cameo)
```

Not every service uses every directory — only the ones it needs. Don't create empty placeholders.

## Conventions

- **One `main` branch.** Environments are selected by the params filename (`params.dev-airgap.bicepparam`), not by branch.
- **Charts:** custom in-repo charts live under `charts/`. Upstream charts (e.g. `jfrog/jfrog-platform`) are referenced by name+version+repo in `service.json` and pulled at deploy time — don't vendor them in git.
- **Secrets:** never in this folder. Set as env vars or pull from Key Vault at deploy.
- **Air-gap:** `images.txt` and `charts.txt` are the manifests of what gets mirrored to Gov ACR before deploy. The shared mirror script reads these from every service.
- **Cluster:** AKS with Azure Managed Istio (`istio.io/rev=asm-1-27`).
- **Cloud:** Azure Government — endpoints are `*.usgovcloudapi.net`, `*.azurecr.us`. Bicep `environment()` resolves these automatically.

## Shared infrastructure

Bicep modules, the orchestrator (`main.bicep`), shared deploy scripts, and Azure env config will live in `../shared/` once the bicep migration completes. They currently sit at `../services-status/bicep/`.

## Adding a new service

Copy the layout from `code-marketplace/` (or any later-migrated service) and replace the service-specific bits — `service.json`, `values.yaml`, `params.*.bicepparam`, `images.txt`, the `<name>.md` deploy guide, and the README.

A `templates/new-service/` skeleton will appear at the repo root once the patterns stabilize across 2–3 services.
