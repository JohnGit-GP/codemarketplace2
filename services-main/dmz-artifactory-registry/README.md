# DMZ Artifactory — registry.fox.oversight.af.mil

Expose the DMZ Artifactory at **https://registry.fox.oversight.af.mil** through the Istio ingress
gateway with a CA-issued certificate, using the same Gateway + VirtualService pattern as the
existing fox-ops Artifactory, so operators, the fox-ops Artifactory and docker clients get the same
trust posture as the clean side.

## Scope (from the ticket)

| Area | Work |
|---|---|
| Certificate | PKI leaf with SANs `registry.fox.oversight.af.mil` + `*.fox.oversight.af.mil` (wildcard enables the docker subdomain method). Four acceptance checks: file sizes, parse, chain to CA, public-key match. Mount as `registry-tls` in `aks-istio-ingress`. |
| DNS | A record → DMZ ingress load balancer IP, plus the wildcard record if the cert carries it. |
| Trust | PKI CA on every non-enrolled client: DMZ jumpbox now; fox-ops Artifactory trust store in the workflow-proof ticket. |
| Exposure | Reachable only from the DMZ jumpbox, fox-ops cluster egress and operator workstations — never the public internet. |
| Routing | Gateway + VirtualService to the DMZ Artifactory backend (UI, `/v2/`, `/artifactory/api/system/ping`). |

Start the certificate and DNS requests now — they have lead time and don't depend on the deploy.

## Acceptance criteria

- [ ] Certificate passes all four checks; expiry date recorded in the runbook.
- [ ] DNS resolves to the DMZ ingress IP from the DMZ jumpbox and from an fox-ops pod (`dig`, no hosts-file entries).
- [ ] UI warning-free on CA-trusting clients; `/v2/` answers through the gateway; `/artifactory/api/system/ping` returns OK from an fox-ops pod.
- [ ] Gateway unreachable from any address outside the allowed set; check and result recorded on the ticket.

## Dependencies

- "DMZ enclave workload foundation for Artifactory" — inter-tier path, namespace.
- "Deploy fox-ops DMZ Artifactory" — the backend to route to.

## Status

Branch created; starting with the Argo CD portion.
