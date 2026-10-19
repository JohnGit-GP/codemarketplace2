# Uptime monitoring (Heartbeat)

One Heartbeat pod on aks-1 checks every service in `manifests/heartbeat-monitors.yml` every
60 seconds and records up/down and response time in Elasticsearch (`heartbeat-*`, kept 30 days).
That file **is** the SLA target list: to monitor a new service, add an entry and redeploy.
Heartbeat reloads the list on its own — the pod is not restarted.

## Add a service

1. **Find what to check.** Prefer a health URL that answers without logging in
   (`/health`, `/healthz`, `/status`, `/api/status`); otherwise the site's main URL.
   From the jumpbox, confirm it answers and note the status code:
   ```bash
   curl -sk -o /dev/null -w '%{http_code}\n' https://newapp.iguana.internal/health
   ```
   Any code below 400 counts as "up" (a 302 to a login page is fine). If the service normally
   answers 401 or 403, list the expected codes with `check.response.status`.

2. **Add an entry** to `manifests/heartbeat-monitors.yml`, under the cluster that hosts it:
   ```yaml
   - id: newapp                       # unique, lowercase, never reuse an old id
     name: New App                    # shown in Kibana
     type: http
     schedule: '@every 60s'
     urls: ["https://newapp.iguana.internal/health"]
     tags: [gl-aks, sla]              # hosting cluster + sla
     ssl.certificate_authorities: [/usr/share/heartbeat/ca/ca-bundle.pem]
   ```
   For something that isn't a website (a database, a TCP service), check that the port answers:
   ```yaml
   - id: newapp-db
     name: New App database
     type: tcp
     schedule: '@every 60s'
     hosts: ["newapp-db.iguana.internal:5432"]
     tags: [gl-aks, sla]
   ```

3. **Deploy it** (from the `elastic/` folder, `cluster3` context):
   ```bash
   ./scripts/deploy.sh diff          # optional: the "heartbeat monitors" section shows your change
   ./scripts/deploy.sh heartbeat
   ```
   The script rejects a file with bad YAML, a duplicate `id`, or an entry missing `type`,
   `schedule` or `urls`/`hosts`.

4. **Verify** after ~2 minutes, in Kibana → Discover, data view `heartbeat-*`:
   `monitor.id : "newapp"` should show a document per minute with `monitor.status: up`.
   If it shows `down`, `error.message` says why (DNS, timeout, TLS, status code).

5. **Commit** the edited `heartbeat-monitors.yml` so the repo stays the source of truth.

## Change or remove a service

- **Change** the URL, schedule or expected status in place, keeping the same `id` — history continues.
- **Pause** without losing history: add `enabled: false` to the entry.
- **Remove**: delete the entry. Its past data stays until it ages out (30 days).

Deploy with `./scripts/deploy.sh heartbeat` either way.

## Certificates

Checks on `https://` URLs verify the server certificate against
`/usr/share/heartbeat/ca/ca-bundle.pem` (secret `heartbeat-ca`) — a PEM file containing every
CA the checks must trust. It starts with the Iguana dog-ops Issuing CA.

A service signed by a **different** CA fails with a certificate error. To trust that CA:

```bash
# 1. See who signed the service's certificate
openssl s_client -connect newapp.example.mil:443 -servername newapp.example.mil -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer
# 2. Get that CA's certificate (PEM) from its owner, append it to your local bundle, and reload:
cat other-ca.pem >> ca-bundle.pem
HEARTBEAT_CA_FILE=ca-bundle.pem ./scripts/deploy.sh heartbeat
```

Until a CA is available, an entry may use `ssl.verification_mode: none` (up/down is still
correct; the certificate isn't checked). The `*.oversight.af.mil` entries do this today —
marked `TODO(CA)` — and should switch to `ssl.certificate_authorities` once that CA is in the bundle.

## Troubleshooting

| Symptom | Check |
|---|---|
| New entry never shows up | `kubectl -n elastic logs deploy/heartbeat-beat-heartbeat \| grep -i -E "error\|monitor"` — usually a YAML mistake |
| `lookup ... no such host` | aks-1 can't resolve the name — DNS |
| `i/o timeout` / `connection refused` | firewall or the service is really down |
| `x509: certificate signed by unknown authority` | add the CA (above) |
| Every check down at once | Heartbeat pod: `kubectl -n elastic get beat heartbeat` and the pod's events |
