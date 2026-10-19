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

## Ticket 6 — Beats on aks-1

**1. Spread ES one pod per VM** (needs 4 nodes in nodepool1 — min was raised to 4).
`manifests/elasticsearch.yaml` requires one ES pod per node. Applying it is a normal ECK
rolling restart, one pod at a time, each waiting for green:
```bash
./scripts/deploy.sh diff        # elasticsearch section: only the added affinity block
./scripts/deploy.sh stack       # SAML_METADATA_FILE not needed — the ConfigMap is kept
kubectl -n elastic get pods -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch -o wide
# want: 3 different NODE values
```
A pod stuck Pending with `didn't match pod anti-affinity rules` means no node without an ES pod
has a free slot — free one (step 3) on any node that has no ES pod.

**2. Heartbeat** — see `HEARTBEAT.md`:
```bash
HEARTBEAT_CA_FILE=/path/to/heartbeat-ca-bundle.pem ./scripts/deploy.sh heartbeat
```

**3. Metricbeat:**
```bash
./scripts/deploy.sh metricbeat
```
It lists any pod left Pending because its node is at the 30-pod limit. A new node doesn't help
(a DaemonSet pod is pinned to its node) and nothing rebalances on its own, so free **one** slot
on each such node, once. DaemonSet pods tolerate a cordon; ordinary pods don't — so:
```bash
N=<node from the Pending list>
kubectl cordon $N
# Pick ONE pod on $N owned by a ReplicaSet (i.e. a Deployment), preferably with 2+ replicas,
# not in kube-system / elastic / aks-istio-*:
kubectl get pods -A --field-selector spec.nodeName=$N \
  -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,OWNER:.metadata.ownerReferences[0].kind,RS:.metadata.ownerReferences[0].name \
  | grep ReplicaSet
kubectl -n <ns> delete pod <pod>     # its replacement lands on another node ($N is cordoned)
kubectl -n elastic get pods -l beat.k8s.elastic.co/name=metricbeat -o wide | grep $N   # Running
kubectl uncordon $N
```
Then `kubectl -n elastic get beat` shows metricbeat `green`, and Kibana → Discover
(`metricbeat-*`) shows `kubernetes.node.*` / `kubernetes.pod.*` documents for every node.

## Ticket 6 — spokes (atl-aks, gl-aks)

Plain Metricbeat (no ECK on the spokes) shipping to `https://elasticsearch.iguana.internal:443`
with its own write-only API key. Context → cluster: `cluster2` = atl-aks, `cluster1` = gl-aks.
gl-aks first needs a free pod slot on every node (raise its pool's min/max as on aks-1).

**1. API key** — Kibana → Dev Tools, one per spoke (replace `atl-aks` for gl-aks):
```
POST /_security/api_key
{
  "name": "metricbeat-atl-aks",
  "role_descriptors": {
    "metricbeat_writer": {
      "cluster": ["monitor", "read_ilm", "read_pipeline"],
      "index": [{ "names": ["metricbeat-*"],
                  "privileges": ["view_index_metadata", "create_doc", "auto_configure"] }]
    }
  },
  "metadata": { "cluster": "atl-aks", "purpose": "metricbeat shipping" }
}
```
The response shows the key once. Save `<id>:<api_key>` — the `id` and `api_key` fields joined by
a colon, **not** `encoded` — to a file only you can read:
```bash
umask 077; printf '%s:%s\n' '<id>' '<api_key>' > ~/metricbeat-atl-aks.key
```

**2. Deploy:**
```bash
ACR_NAME=<acr> SPOKE_API_KEY_FILE=~/metricbeat-atl-aks.key SPOKE_CA_FILE=/path/to/heartbeat-ca-bundle.pem \
  ./scripts/deploy.sh spoke cluster2 atl-aks
shred -u ~/metricbeat-atl-aks.key        # it now lives only in the secret
```
The script refuses to run if the context's nodes don't belong to the named cluster. Later runs
need neither file (secret and CA are kept). Pods left Pending on a full node: free one slot
(same steps as aks-1, with `--context`).

**3. Verify:**
```bash
kubectl --context cluster2 -n elastic-beats logs ds/metricbeat --tail=50 | grep -i -E '"log.level":"error"|connection' | tail
```
Kibana → Dev Tools — each cluster should appear with its node count:
```
GET metricbeat-*/_search?size=0
{ "query": { "range": { "@timestamp": { "gte": "now-5m" } } },
  "aggs": { "c": { "terms": { "field": "labels.cluster" },
    "aggs": { "nodes": { "cardinality": { "field": "kubernetes.node.name" } } } } } }
```

**Revoke a spoke** (lost key, decommissioned cluster): `DELETE /_security/api_key {"name": "metricbeat-atl-aks"}`,
then create a new one and re-run step 2 with `SPOKE_API_KEY_FILE`.

## Ticket 6 — Azure metrics

One Metricbeat pod on aks-1 reads Azure Monitor (Gov endpoints) for the 3 AKS clusters
(`container_service`) and their node scale sets (`compute_vm_scaleset`). aks-1 egress to
`login.microsoftonline.us` and `management.usgovcloudapi.net` is open (verified 2026-10-19).

**1. Service principal** (portal.azure.us; needs app-registration rights + Owner / User Access
Administrator / RBAC Administrator on the subscription — else ask the Azure admin):
- Entra ID → App registrations → New registration: **`bm-igna004-100-fox-ops-ars-metricbeat`**,
  single tenant, no redirect URI. Note the *Application (client) ID*.
- Certificates & secrets → New client secret, 12 months. Copy the **Value** (shown once). Note the expiry.
- Subscriptions → bm-igna004-100-fox-ops-sub → Access control (IAM) → Add role assignment →
  **Monitoring Reader** → members: the app → Review + assign.

**2. Secret on aks-1** — paste the secret Value into a file, never onto a command line:
```bash
umask 077; cat > ~/sp.secret          # paste, Enter, Ctrl-D
kubectl -n elastic create secret generic azure-metrics-sp \
  --from-file=client_secret=$HOME/sp.secret \
  --from-literal=client_id=<application-client-id> \
  --from-literal=tenant_id=4dcf8fb0-8060-4ec6-9365-38894b949acb \
  --from-literal=subscription_id=ac488a17-c5fd-4fcf-a55d-344784fcd48a
shred -u ~/sp.secret
```

**3. Deploy and verify:**
```bash
./scripts/deploy.sh azure
kubectl -n elastic logs deploy/metricbeat-azure-beat-metricbeat --tail=100 | grep -i -E '"log.level":"error"|azure' | tail
```
After ~10 minutes, Kibana → Dev Tools:
```
GET metricbeat-*/_search?size=0
{ "query": { "bool": { "filter": [ { "term": { "event.module": "azure" } },
                                   { "range": { "@timestamp": { "gte": "now-30m" } } } ] } },
  "aggs": { "t": { "terms": { "field": "azure.resource.type" },
    "aggs": { "r": { "terms": { "field": "azure.resource.name", "size": 20 } } } } } }
```
Expect `Microsoft.ContainerService/managedClusters` (3 clusters) and
`Microsoft.Compute/virtualMachineScaleSets` (their node pools).

| Log error | Fix |
|---|---|
| `AADSTS7000215` invalid client secret | the secret Value (not the Secret ID) — recreate `azure-metrics-sp` |
| `AADSTS700016` application not found | wrong client ID or tenant |
| `AuthorizationFailed` | Monitoring Reader not assigned (or not yet propagated — wait 10 min) |
| no errors, no data for one type | resource group names in `manifests/metricbeat-azure.yaml` |

**Renewal:** when the client secret expires Azure metrics stop silently. Create a new secret in
the portal, recreate `azure-metrics-sp` (step 2, with `--dry-run=client -o yaml | kubectl apply -f -`),
then `kubectl -n elastic rollout restart deploy/metricbeat-azure-beat-metricbeat`.

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
