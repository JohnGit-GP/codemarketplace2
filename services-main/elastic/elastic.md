# Deploying elastic on aks-1

Runbook for the Elastic Stack via ECK. Ticket numbers refer to `TICKETS.md`.
Context, decisions, and gotchas are in `README.md` — read that first.

> **Status:** tickets 1, 2, 4 and the Kibana half of 5 are executable as written.
> Everything else is described but depends on open decisions.

---

## Ticket 1 — Stage artifacts (connected side)

```bash
cd services-main/elastic
./scripts/mirror-images.sh pull
tar -czf elastic-bundle.tar.gz cache/ "$(command -v crane)"
scp elastic-bundle.tar.gz <user>@<airgap-host>:~/
```

## Ticket 2 — aks-1 platform prep and ECK operator

```bash
tar -xzf ~/elastic-bundle.tar.gz -C services-main/elastic/
cd services-main/elastic
export ACR_NAME=<gov-acr-name>
./scripts/mirror-images.sh push             # verifies every image is linux/amd64
kubectl get storageclass                    # pick one; note its reclaim policy
kubectl config current-context              # must be aks-1
```

`deploy.sh` installs the CRDs and operator first; you can stop after the operator is Running
if you're closing this ticket separately.

## Ticket 3 — Certificates and DNS

```bash
for c in kibana es-ingest; do
  openssl x509 -in $c-fullchain.crt -noout -ext subjectAltName -dates
done
kubectl -n aks-istio-ingress create secret tls kibana-tls    --cert=kibana-fullchain.crt    --key=kibana.key
kubectl -n aks-istio-ingress create secret tls es-ingest-tls --cert=es-ingest-fullchain.crt --key=es-ingest.key
kubectl -n aks-istio-ingress get svc aks-istio-ingressgateway-internal \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'     # A records → this IP
```

The CA is name-constrained to `snail.internal`; a request for any other name will be refused.

## Tickets 4 and 5 — Elasticsearch and Kibana

```bash
export ACR_NAME=<gov-acr-name> STORAGE_CLASS=<class>
./scripts/deploy.sh
./scripts/check-status.sh
```

`deploy.sh` waits for ES green (up to 20 minutes on first rollout) and Kibana green.

Retrieve the `elastic` password without putting it on a command line anyone else sees:

```bash
kubectl -n elastic get secret elasticsearch-es-elastic-user \
  -o go-template='{{.data.elastic | base64decode}}'; echo
```

Test Kibana before exposing it:

```bash
kubectl -n elastic port-forward svc/kibana-kb-http 5601
# https://localhost:5601  (ECK self-signed cert — expected browser warning)
```

**Gateway exposure** (`manifests/istio.yaml`) is written once README decision 1 is made.
Verify before DNS propagates:

```bash
IP=<gateway-ip>
curl -v --resolve kibana.snail.internal:443:$IP    https://kibana.snail.internal/api/status
curl -v --resolve es-ingest.snail.internal:443:$IP https://es-ingest.snail.internal/
```

## Ticket 9 — License

```bash
LICENSE_FILE=./license.json ./scripts/deploy.sh      # idempotent; adds the eck-license secret
```

## Tickets 6–8, 10–13

Described in `TICKETS.md`. Manifests and procedures will be added here as each ticket's
open decision is resolved.

---

## Rollback

```bash
kubectl -n elastic delete kibana/kibana elasticsearch/elasticsearch
```

**PVCs are retained deliberately** — the data survives. Delete them only when you intend to
destroy the cluster's data. The operator and CRDs are cluster-wide; removing CRDs deletes
every ECK resource in every namespace, so don't.

## Acceptance record

| AC | Witnessed by | Date |
|---|---|---|
| AC1 | | |
| AC2 | | |
