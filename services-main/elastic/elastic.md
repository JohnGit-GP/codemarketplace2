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
kubectl config current-context                   # cluster3 (= aks-1)
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

Waits for ES green (up to 20 min on first rollout) and Kibana green. If the TLS secrets aren't
in place yet it **skips the Istio Gateway** — the internal gateway is shared, so it never gets a
Gateway pointing at certificates that don't exist. Create the secrets, then re-run
`./scripts/deploy.sh stack`; every step is idempotent and the gateway is applied on that run.

**Verify STRICT is enforced on Kibana** — this must **fail** (the probe pod has no sidecar).
Use an image already in the ACR, in a throwaway namespace with no Istio label:
```bash
kubectl create ns mtls-test
kubectl -n mtls-test run mtls-test --restart=Never \
  --image="${ACR_NAME}.azurecr.us/elasticsearch/elasticsearch:9.5.4" \
  --command -- curl -sS -m 10 -o /dev/null -w 'HTTP %{http_code}\n' http://kibana-kb-http.elastic.svc:5601/
sleep 60; kubectl -n mtls-test logs mtls-test   # want "Connection reset" / HTTP 000
kubectl delete ns mtls-test
```
Elasticsearch itself is HTTPS-only and rejects plain HTTP regardless.

**Credentials** — never on a shared command line:
```bash
kubectl -n elastic get secret elasticsearch-es-elastic-user \
  -o go-template='{{.data.elastic | base64decode}}'; echo
```

**API access via port-forward.** ES serves HTTPS with ECK's CA; the cert names the service, so
use `--resolve` to keep hostname verification on. Strip `_comment` — Elasticsearch rejects unknown
top-level fields:
```bash
kubectl -n elastic port-forward svc/elasticsearch-es-http 9200 & PF_ES=$!
kubectl -n elastic get secret elasticsearch-es-http-certs-public -o go-template='{{index .data "ca.crt" | base64decode}}' > /tmp/es-ca.crt
PW=$(kubectl -n elastic get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')
ES="https://elasticsearch-es-http.elastic.svc:9200"
CURL=(curl -sS --cacert /tmp/es-ca.crt --resolve elasticsearch-es-http.elastic.svc:9200:127.0.0.1 -u "elastic:$PW")

jq 'del(._comment)' manifests/es-api/ilm-beats-30d.json |
  "${CURL[@]}" -H 'Content-Type: application/json' -X PUT "$ES/_ilm/policy/beats-30d" -d @-
kill $PF_ES
```
Nightly snapshots (`manifests/es-api/slm-nightly.json`) go on after the `azure-snapshots`
repository exists.

**Through the gateway**, before DNS propagates:
```bash
IP=<gateway-ip>
curl -v --resolve kibana.iguana.internal:443:$IP        https://kibana.iguana.internal/api/status
curl -v --resolve elasticsearch.iguana.internal:443:$IP https://elasticsearch.iguana.internal/
```

## Ticket 7 — SSO with Entra ID

**1. Trial license** (30 days; unlocks SAML). Request the Enterprise license the same day.
```bash
kubectl apply -f manifests/eck-trial-license.yaml
kubectl -n elastic-system get cm elastic-licensing -o jsonpath='{.data.eck_license_level}{"\n"}'   # enterprise_trial
```
When the Enterprise license arrives: `LICENSE_FILE=./license.json ./scripts/deploy.sh operator`.

**2. Entra enterprise app** (Azure Gov portal → Entra ID → Enterprise applications → New →
Create your own → non-gallery), Single sign-on → SAML:

| Field | Value |
|---|---|
| Identifier (Entity ID) | `https://kibana.iguana.internal` |
| Reply URL (ACS) | `https://kibana.iguana.internal/api/security/saml/callback` |
| Sign on URL | `https://kibana.iguana.internal` |
| Logout URL | `https://kibana.iguana.internal/logout` |
| Group claim | Add a group claim → **Groups assigned to the application**, source **Group ID** |

Users and groups: assign `elk_admins` plus whoever should read. Download **Federation Metadata
XML** (SAML Certificates section). Note the `elk_admins` **Object ID**. Elasticsearch never
calls Entra — the metadata is a file — but users' browsers must reach `login.microsoftonline.us`.

Preview any `stack` run first — read-only, prints only what would change:
```bash
SAML_METADATA_FILE=/path/to/Kibana.xml ./scripts/deploy.sh diff
```

**3. Turn SAML on** (rolling restart of ES, then Kibana):
```bash
SAML_METADATA_FILE=/path/to/Kibana.xml ./scripts/deploy.sh stack
```

**4. Role mappings** (port-forward and `CURL` as above):
```bash
jq 'del(._comment)' manifests/es-api/role-mapping-saml-viewer.json |
  "${CURL[@]}" -H 'Content-Type: application/json' -X PUT "$ES/_security/role_mapping/saml-viewer" -d @-
jq 'del(._comment)' manifests/es-api/role-mapping-elk-admins.json | sed "s/ELK_ADMINS_GROUP_ID/$ELK_ADMINS_GROUP_ID/" |
  "${CURL[@]}" -H 'Content-Type: application/json' -X PUT "$ES/_security/role_mapping/saml-elk-admins" -d @-
```

**5. Verify:** a non-admin signs in via "Log in with Entra ID" and lands read-only; an
`elk_admins` member sees Stack Management. The user menu → Profile shows the roles granted.

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
