# Deploying elastic on aks-1

Runbook for the Elastic Stack via ECK. Ticket numbers refer to `TICKETS.md`.
Context, decisions, and gotchas are in `README.md` — read that first.

**How the pieces fit:** the ECK **CRDs** teach Kubernetes the `Elasticsearch`, `Kibana`, and `Beat`
resource types; the ECK **operator** watches for those resources and builds the pods, services,
secrets, and volumes behind them. So the operator goes in first, once per cluster (ticket 1), and
Elasticsearch and Kibana are then just short manifests the operator acts on (ticket 3). Upgrading
the stack later is a change to `version` in those manifests — the operator rolls it.

---

## Ticket 1 — Install ECK

**Connected side:**
```bash
cd services-main/elastic
./scripts/mirror-images.sh pull
tar -czf elastic-bundle.tar.gz cache/
scp elastic-bundle.tar.gz <user>@<airgap-host>:~/
```

**Air-gapped side:**
```bash
tar -xzf ~/elastic-bundle.tar.gz -C services-main/elastic/
cd services-main/elastic
export ACR_NAME=<acr-name>
kubectl config current-context                   # must be aks-1
./scripts/mirror-images.sh push                  # load, arch-check, tag, push
./scripts/deploy.sh operator
kubectl -n elastic-system get pods               # elastic-operator Running
```

## Ticket 2 — Certificates, DNS, network

```bash
for c in kibana elasticsearch; do
  openssl x509 -in $c-fullchain.crt -noout -ext subjectAltName -dates
done
kubectl -n aks-istio-ingress create secret tls kibana-tls        --cert=kibana-fullchain.crt        --key=kibana.key
kubectl -n aks-istio-ingress create secret tls elasticsearch-tls --cert=elasticsearch-fullchain.crt --key=elasticsearch.key
kubectl -n aks-istio-ingress get svc aks-istio-ingressgateway-internal \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'     # A records → this IP
```

Both certs come from the **Iguana dog-ops Issuing CA**, name-constrained to `iguana.internal`.
DNS records go in the `iguana.internal` zone. Firewall: atl-aks and gl-aks → that IP, TCP 443.

## Ticket 3 — Elasticsearch and Kibana

```bash
./scripts/deploy.sh stack
./scripts/check-status.sh
```

Waits for ES green (up to 20 min on first rollout) and Kibana green. If the TLS secrets from
ticket 2 aren't in place yet it warns and continues — ES and Kibana still come up; the gateway
starts serving once the secrets exist.

**Verify STRICT is enforced** — this must **fail** (the probe pod has no sidecar):
```bash
kubectl run mtls-probe --rm -i --restart=Never -n default --image=curlimages/curl -- \
  curl -sS -m 5 http://elasticsearch-es-http.elastic.svc:9200/ ; echo "exit=$?"
# JSON back = STRICT NOT in force, ES readable in plaintext. Stop and fix.
```

**Credentials** — never on a shared command line:
```bash
kubectl -n elastic get secret elasticsearch-es-elastic-user \
  -o go-template='{{.data.elastic | base64decode}}'; echo
```

**Retention.** `port-forward` works under STRICT (it enters the pod over loopback, which the
sidecar doesn't intercept). Strip `_comment` — Elasticsearch rejects unknown top-level fields:
```bash
kubectl -n elastic port-forward svc/elasticsearch-es-http 9200 &
PW=$(kubectl -n elastic get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')
jq 'del(._comment)' manifests/es-api/ilm-beats-30d.json |
  curl -sS -u "elastic:$PW" -H 'Content-Type: application/json' \
    -X PUT http://localhost:9200/_ilm/policy/beats-30d -d @-
```
Nightly snapshots (`manifests/es-api/slm-nightly.json`) go on after the `azure-snapshots`
repository exists.

**Through the gateway**, before DNS propagates:
```bash
IP=<gateway-ip>
curl -v --resolve kibana.iguana.internal:443:$IP        https://kibana.iguana.internal/api/status
curl -v --resolve elasticsearch.iguana.internal:443:$IP https://elasticsearch.iguana.internal/
```

## Tickets 4–6

Described in `TICKETS.md`. Procedures are added here as each is worked. For the license (ticket 5):
```bash
LICENSE_FILE=./license.json ./scripts/deploy.sh operator    # idempotent
```

---

## Rollback

```bash
kubectl -n elastic delete kibana/kibana elasticsearch/elasticsearch
```

PVCs are kept, and the StorageClass is `Retain`, so the Azure disks survive even if a PVC is
deleted. Remove them deliberately. Don't delete the ECK CRDs — that deletes every ECK resource
in every namespace.

## Acceptance record

| AC | Witnessed by | Date |
|---|---|---|
| AC1 | | |
| AC2 | | |
