# elastic

Elasticsearch + Kibana for Gov Cloud (TEST CUI), deployed as one operational unit —
Elasticsearch internal-only, Kibana exposed through the Istio internal ingress gateway.

## Purpose

**Epic value statement:** *As a Snail tenant, I want to be able to monitor TEST-specific
uptimes and availability, so that I can comply with SLAs and Cyber requirements.*

| AC | Criterion | What satisfies it |
|---|---|---|
| AC1 | Elastic is available as a data resource for tenant metric monitoring | ES cluster green, reachable in-cluster, credentials issued, retention policy applied |
| AC2 | Kibana is available as a data resource for tenant metric monitoring | Kibana reachable over TLS at its hostname, tenant can log in and see uptime/availability data |

**Scope note:** the ACs as written are met by "the stack is up." The value statement
needs *data flowing* — uptime and availability metrics for TEST targets — which means
something has to ship them (Heartbeat / Elastic Agent) and a dashboard has to exist.
Confirm with the ticket owner whether ingestion and dashboards are in this epic or a
follow-on before sizing the work. This runbook treats them as Phase 5, in scope.

> **Status: scaffolded — deployment method not yet chosen.** See *Open decisions* below.
> Nothing in here has been deployed. Do not follow `elastic.md` until the TODOs are resolved.

## Environment facts

Verified during the `code-marketplace` deployment. These are the values that were
wrong or unknown in that service's docs and cost real time — start from them.

| | Value |
|---|---|
| Cloud | Azure Government (`*.usgovcloudapi.net`, `*.azurecr.us`) |
| Cluster | AKS with Azure Managed Istio |
| **Istio revision** | **`asm-1-29`** — namespace label `istio.io/rev=asm-1-29` |
| Istio ingress | `aks-istio-ingress` ns, svc `aks-istio-ingressgateway-internal` |
| **Gateway TLS secrets** | live in **`aks-istio-ingress`**, NOT the app namespace |
| Sidecars | native sidecars — pods show `Init:1/2` permanently and `READY 1/1`. Normal. |
| Registry | Gov ACR, images mirrored before deploy; no egress at runtime |
| Image transfer | **`crane`**, not docker — no daemon on either host |
| ACR auth (air-gap) | `az acr login --expose-token` + `crane auth login` (docker CLI absent) |
| Artifactory (if needed) | REST API on **port 8082**, path prefix `/artifactory`, PERMISSIVE mTLS |
| Transfer | connected host → `scp` → air-gapped host |

## Gotchas carried forward

- **Pull images with `--platform linux/amd64`.** A pull on an arm64 workstation
  produces an image the AKS nodes cannot run, discovered only after transfer.
- **Never put tarballs or caches inside `charts/`.** Helm packs the whole chart
  directory into its release secret and the API server rejects anything over 3 MiB.
- **Check the image ENTRYPOINT before adding a subcommand to chart `args`.**
  Duplicating it produces a CrashLoopBackOff with an argument-parse error.
- **Commit scripts with the exec bit** (`git update-index --chmod=+x`).
- **Verify chart paths resolve** — `HELM_CHART_PATH` pointing at a non-existent
  directory fails only at the final step, after everything else has run.
- **Confirm service ports from the cluster**, not from assumption. A wrong port
  yields a healthy-looking pod serving nothing.

## Open decisions

These block the runbook. Answer them before writing chart or manifest content.

1. **ECK operator vs upstream Helm charts.** Elastic's standalone
   `elasticsearch`/`kibana` charts are deprecated for 8.x in favour of ECK.
   ECK means CRDs + an operator (and mirroring the operator image); Helm means two
   releases and no CRDs. This decides the shape of `deploy.sh`, `charts/` vs
   `manifests/`, and `images.txt`.
2. **Version** to pin.
3. **Storage** — node count, PVC size per node, and which StorageClass. Elasticsearch
   is a StatefulSet; this is the one irreversible sizing decision.
4. **Security** — ES 8.x enables TLS and auth by default. Self-signed internal certs,
   or the organizational PKI as used for Kibana's public endpoint?
5. **Kibana hostname** and whether a cert already exists for it.
6. **Retention / ILM** — affects sizing and whether snapshots need an Azure repository.

## File index

| File | Purpose |
|---|---|
| `elastic.md` | Deploy runbook (skeleton — follows the proven air-gap sequence) |
| `service.conf` | Env config consumed by `scripts/deploy.sh` |
| `service.json` | Namespace, Istio revision, component list, secret list |
| `images.txt` | Container images to mirror to Gov ACR |
| `charts.txt` | Upstream Helm charts to mirror (if the Helm path is chosen) |
| `scripts/mirror-images.sh` | `crane` pull/push across the air gap — **working** |
| `scripts/check-status.sh` | Probe workloads, storage, routing, cluster health — **working** |
| `scripts/deploy.sh` | Namespace + label + secret + render — install step is a TODO |
| `cache/` | Local image tarballs (gitignored) |

## Status

| Environment | State |
|---|---|
| Dev (Gov air-gap) | Not started — scaffolded only |
| Prod (Gov) | Not planned |
