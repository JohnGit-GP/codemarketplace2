# elastic

Elastic Stack on **aks-1** (TEST, dog-ops), deployed with **Elastic Cloud on Kubernetes (ECK)**.
Elasticsearch and Kibana run on aks-1; Metricbeat and Heartbeat run on each monitored cluster
and ship back to aks-1. Kibana users sign in with Snail accounts via Entra ID SAML.

> **Status: design in progress — nothing deployed.** Blocked items are listed under
> *Open decisions*. `elastic.md` is the runbook; `TICKETS.md` is the tracking breakdown.

## Purpose

*As a Snail tenant, I want to be able to monitor TEST-specific uptimes and availability,
so that I can comply with SLAs and Cyber requirements.*

| AC | Criterion | Verified by |
|---|---|---|
| AC1 | Elastic is available as a data resource for tenant metric monitoring | ES cluster green on aks-1; Metricbeat + Heartbeat data arriving from aks-1, atl-aks, gl-aks |
| AC2 | Kibana is available as a data resource for tenant metric monitoring | Tenant signs in to `https://kibana.iguana.internal` with their Snail account via SAML and sees the baseline uptime/availability dashboard |

## Scope

**In:** ECK operator + CRDs on aks-1 · Elasticsearch + Kibana with persistent storage ·
Kibana SAML with Entra ID and group→role mapping · Kibana and ES ingest endpoint exposed through
the aks-1 Istio internal gateway with certs from the **Iguana dog-ops Issuing CA** · network paths
from monitored clusters to aks-1 · Metricbeat + Heartbeat on aks-1, atl-aks, gl-aks, then Azure
metrics · baseline uptime/availability dashboard.

**Out:** log aggregation / SIEM · alerting and notification routing · APM · clusters outside
the fox-ops enclave.

## Architecture

```mermaid
flowchart LR
    subgraph spokes["Monitored clusters"]
        A1["aks-1<br/>Metricbeat + Heartbeat"]
        A2["atl-aks<br/>Metricbeat + Heartbeat"]
        A3["gl-aks<br/>Metricbeat + Heartbeat"]
    end
    subgraph hub["aks-1 · namespace elastic"]
        GW["Istio internal gateway<br/>terminates TLS"]
        ES["Elasticsearch<br/>(ECK, StatefulSet + PVCs)"]
        KB["Kibana<br/>(ECK)"]
    end
    Entra["Entra ID<br/>(SAML IdP)"]
    User["Snail tenant<br/>browser"]

    A1 --> ES
    A2 -->|"elasticsearch.iguana.internal:443"| GW
    A3 -->|"elasticsearch.iguana.internal:443"| GW
    GW --> ES
    ES --> KB
    User -->|"kibana.iguana.internal:443"| GW
    GW --> KB
    User <-->|"SAML redirect"| Entra
```

## Decided

| | Value | Source |
|---|---|---|
| Deployment method | **ECK** (operator + CRDs) | ticket |
| Hub cluster | **aks-1**, dog-ops | ticket |
| ECK version | **3.5.0** | latest release |
| Stack version | **9.5.4** (Elasticsearch, Kibana, Metricbeat, Heartbeat) | latest 9.x release |
| Namespaces | `elastic` (stack), `elastic-system` (operator) | ECK convention |
| Hostnames | **`kibana.iguana.internal`**, **`elasticsearch.iguana.internal`** | confirmed by you |
| TLS model | **Istio.** ECK HTTP TLS disabled; Istio mTLS **STRICT** in `elastic`; operator namespace in the mesh with webhook port 9443 excluded; gateway terminates TLS at the edge | confirmed by you |
| Certificates | **Iguana dog-ops Issuing CA** — name-constrained to `iguana.internal`; names follow `<svc>.iguana.internal` | ticket (corrected: ticket text said `snail.internal`) |
| Kibana auth | SAML via Entra ID + a `basic` provider kept for break-glass | ticket |
| License | **Elastic Enterprise** — required for SAML | ticket |
| Monitored clusters | aks-1, atl-aks, gl-aks (then Azure metrics) | ticket |
| Transport port | 9300 excluded from the Istio sidecar | ECK Istio guidance |
| mmap | `node.store.allow_mmap: false` — avoids a privileged sysctl init container | locked-down AKS |
| Retention | **30 days, all data** (Metricbeat, Heartbeat, snapshots). ILM rollover daily, delete 30 days after | confirmed |
| Sizing | 3 nodes × **256Gi** — expandable online; re-measure once aks-1 Beats are running (ticket 4) | 30-day estimate |
| Storage | **`managed-csi-premium-retain`** — Premium SSD, `Retain`, `WaitForFirstConsumer` (`manifests/storageclass.yaml`). Kibana needs no storage. | confirmed; every built-in disk class on aks-1 is `Delete` |

## Environment facts

> **⚠ UNVERIFIED FOR aks-1.** These were verified on the code-marketplace cluster, which is
> **not** aks-1. Treat every row as an assumption until checked on aks-1 — the mTLS mode in
> particular matters: STRICT is set on the `elastic` namespace regardless of the mesh default.

| | Value |
|---|---|
| Cloud | Azure Government |
| Istio revision | `asm-1-29` — namespace label `istio.io/rev=asm-1-29` — **✓ verified on aks-1** |
| Istio mTLS | PERMISSIVE (observed) |
| Ingress | `aks-istio-ingress` ns, label `istio=aks-istio-ingressgateway-internal` — **✓ verified on aks-1** |
| **Gateway TLS secrets** | live in **`aks-istio-ingress`**, not the app namespace |
| Sidecars | native — pods show `Init:1/2` permanently with `READY 1/1`. Normal. |
| Registry | Gov ACR (name supplied at runtime via `ACR_NAME`) — **✓ aks-1 pull access confirmed** (prior deployments) |
| Image transfer | `docker pull --platform linux/amd64` + `docker save` → tar → `docker load` + push |
| ACR auth | `az acr login -n <acr>` |

## Gotchas carried forward

- **9300 must bypass the sidecar.** Otherwise inter-node transport is encrypted twice and the
  cluster never forms. The annotations are in `manifests/elasticsearch.yaml`.
- **The CA can't sign cluster-local names** (name-constrained to `iguana.internal`), and doesn't
  need to: in-cluster encryption is mesh mTLS, and the Iguana certs live only at the gateway.
- **Anything connecting through the gateway must trust the Iguana chain** — Beat pods on the spokes
  and tenant workstations for Kibana.
- **Never deploy ES/Kibana without the STRICT PeerAuthentication.** Their HTTP TLS is off; STRICT is
  the only thing stopping plaintext reads from a pod without a sidecar. `deploy.sh` applies it first.
- **The operator's webhook port (9443) must bypass its sidecar.** The API server isn't in the mesh;
  without the exclusion every `kubectl apply` of an ECK resource is rejected.
- **Kibana refuses to start on unknown config keys.** Check every `config:` key against the 9.5 docs.
- **CRDs are too large for client-side apply.** Use `kubectl apply --server-side`.
- **Never put tarballs in a directory Helm or kubectl will read as manifests.** Cache lives in `cache/`.
- **Credentials never on a kubectl command line** — they land in container logs.
- **30 days is the ceiling for SLA reports too.** Anything older is deleted — monthly SLA reports
  must be produced (or exported) before the data ages out. Snapshots expire at 30 days as well,
  so they can't be used to reach further back.
- **Entra group overage:** SAML tokens stop listing groups past ~150 memberships. Configure
  the enterprise app to emit only *groups assigned to the application*.

## Open decisions

1. **Tenant isolation.** Do tenants see only their own services (Kibana space per tenant +
   document-level security) or one shared view?
2. **Remote Beats delivery.** ECK operator is scoped to aks-1. On atl-aks / gl-aks, deploy
   Beats as plain manifests (recommended — no CRDs on every cluster) or install ECK there too?
3. **Azure metrics** — needs Azure Monitor API egress from aks-1 and a service principal.

## File index

| File | Purpose |
|---|---|
| `elastic.md` | Deploy runbook |
| `TICKETS.md` | Epic breakdown — one entry per tracking ticket |
| `service.conf` | Versions, names, hostnames, sizing — consumed by `deploy.sh` |
| `service.json` | Namespaces, Istio revision, component list |
| `images.txt` | Images to mirror to Gov ACR |
| `manifests.txt` | Upstream manifests to fetch across the gap (ECK CRDs + operator) |
| `manifests/elasticsearch.yaml` | ES cluster (envsubst template) |
| `manifests/kibana.yaml` | Kibana (envsubst template) |
| `manifests/peerauthentication.yaml` | STRICT mTLS for the `elastic` namespace — required |
| `manifests/istio.yaml` | Gateway + VirtualServices for Kibana and Elasticsearch |
| `manifests/storageclass.yaml` | `managed-csi-premium-retain` |
| `manifests/es-api/ilm-beats-30d.json` | ILM policy: daily rollover, delete at 30 days |
| `manifests/es-api/slm-nightly.json` | Nightly snapshots, 30-day expiry |
| `scripts/mirror-images.sh` | Docker pull/save + load/tag/push, arch-checked; fetches ECK manifests |
| `scripts/deploy.sh` | `operator` (CRDs, meshed operator, license) · `stack` (STRICT mTLS, storage, ES, Kibana, gateway) · `all` |
| `scripts/check-status.sh` | ECK resource health, PVCs, routing, events |
