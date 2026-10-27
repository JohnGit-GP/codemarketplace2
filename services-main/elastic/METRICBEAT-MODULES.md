# Metricbeat modules — research and recommendations

What else Metricbeat could monitor in the FOX environment beyond today's setup (kubelet node/pod/
container metrics on all three clusters, Heartbeat uptime checks, Azure Monitor for AKS and node
scale sets). Checked against Metricbeat 9.x and ECK 3.5.

**Constraints that shaped every recommendation**
- **Air-gapped:** all modules ship inside the Metricbeat image already in the ACR. Anything needing
  a *new* image (kube-state-metrics, Filebeat) has to be mirrored first.
- **Pod slots:** 30 per node. Prefer config added to existing pods or one small Deployment; avoid
  new DaemonSets.
- **Disk:** 30-day retention on 3 × 256 Gi. Every module adds data — confirm the storage sizing
  check before enabling more than one.
- **Locked-down clusters:** Azure Policy / Gatekeeper run on the clusters, so options needing root,
  hostPath or hostNetwork are likely to be refused.

## Summary

| # | Module | Adds | New image | New pods | Data | Recommend |
|---|---|---|---|---|---|---|
| 1 | Kubernetes **state** + **event** | Deployment/pod health, restarts, Pending/CrashLoop, PVC status, K8s warning events | No* | 0–1 per cluster | Medium | **Yes — high value** |
| 2 | **Elastic Stack self-monitoring** | ES heap, disk, shard health, indexing rate; Kibana response times | No (metrics) | 0 (sidecars) | Medium | **Yes — high value** |
| 3 | **Istio** (ingress gateway + istiod) | Request rate, 5xx, latency for every service behind the gateway | No | 0 | Low–medium | **Yes — scoped** |
| 4 | **Azure** (more metric sets) | ACR, load balancers, managed disks | No | 0 | Low | Optional — cheap |
| 5 | **Prometheus** (app endpoints) | App metrics: GitLab exporter, Argo CD, others | No | 0 | Varies | On request from app teams |
| 6 | **System** (host-level) | Per-host load, processes, filesystems | No | 0 | Medium | **No** — needs root/hostPath; kubelet covers most |

\* Clusters already run `ama-metrics-ksm` (Azure's kube-state-metrics) in `kube-system`; reusing it
avoids a new image. Deploying our own kube-state-metrics would need one mirrored image.

## 1. Kubernetes state metrics and events — recommended

- **What:** `state_*` metric sets (`state_deployment`, `state_pod`, `state_container`,
  `state_statefulset`, `state_daemonset`, `state_node`, `state_persistentvolumeclaim`, …) report the
  *desired vs actual* state of workloads; `event` collects Kubernetes events (FailedScheduling,
  BackOff, OOMKilled, Unhealthy).
- **Why:** today we see resource *usage*, not whether workloads are healthy. This shows a deployment
  at 0/2 replicas, a pod restart loop or a stuck PVC — usually before Heartbeat sees an outage — and
  the "no pod slot" problem we hit would have been one Pending-pods panel.
- **Needs:** a kube-state-metrics endpoint (`state_*`). First check whether `ama-metrics-ksm` is
  reachable and complete enough:
  `kubectl -n kube-system get svc | grep ksm` and curl its `/metrics` from a pod. If not, mirror
  `registry.k8s.io/kube-state-metrics/kube-state-metrics` and run one replica per cluster.
  RBAC: add `events` (list/watch) to the existing ClusterRole.
- **How:** cluster-wide data must be collected **once per cluster**, not once per node — run it as
  one extra Metricbeat Deployment per cluster (aks-1 via ECK, spokes via the spoke manifest).
- **Cost:** 1 pod per cluster (+1 if running our own kube-state-metrics); medium data volume (tune
  `period` to 60s).

## 2. Elastic Stack self-monitoring — recommended

- **What:** ECK's built-in `spec.monitoring` on the Elasticsearch and Kibana resources adds a
  Metricbeat sidecar to each pod and fills Kibana's **Stack Monitoring** app: JVM heap, disk per
  node, shard allocation, indexing/search rates, Kibana request latency.
- **Why:** everything is monitored except the monitoring stack itself. Our biggest operational risk
  is ES disks filling (writes stop at ~90%), and this is the standard way to see it coming.
- **Needs:** `spec.monitoring.metrics.elasticsearchRefs` pointing at the cluster (same cluster is
  acceptable for TEST; a separate monitoring cluster is the production pattern). Logs collection
  (`spec.monitoring.logs`) additionally needs the Filebeat image mirrored — optional.
- **Cost:** no new pods (sidecars inside existing ES/Kibana pods, so no pod-slot issue); a **rolling
  restart of ES and Kibana** when enabled; `.monitoring-*` data with its own short retention.

## 3. Istio — recommended, scoped

- **What:** `istiod` metric set (control plane, port 15014) and `proxy` metric set (Envoy, port 15090).
- **Why:** the **internal ingress gateway** fronts every SLA service. Its Envoy metrics give request
  rate, 5xx rate and latency *per hostname* — the "is it erroring for users" view that complements
  Heartbeat's "does it answer".
- **Scope it:** collect `proxy` from the **ingress gateway pods only** (and `istiod`), not every
  sidecar — per-sidecar collection across three clusters is high-cardinality and high-volume.
- **Needs:** Azure-managed Istio (asm-1-29) exposes these ports in `aks-istio-system` /
  `aks-istio-ingress`; confirm Metricbeat pods can reach them (network policy, mTLS on 15014). Config
  only — added to the existing aks-1/spoke Metricbeat or the per-cluster Deployment from item 1.
- **Cost:** no new pods; low–medium data.

## 4. More Azure metric sets — optional

Config-only additions to `manifests/metricbeat-azure.yaml`: `container_registry` (ACR pull failures
and storage), `monitor` for the gateway **load balancer** health-probe status, and managed disk
IOPS/throughput for the ES data disks. Each adds a few Azure Monitor API calls per 5 minutes (small
per-call charge — see the "Charges amounted to" log lines). Worth it for the load balancer.

## 5. Prometheus scraping — on request

The `prometheus` module scrapes any `/metrics` endpoint. Candidates already running:
`gitlab-gitlab-exporter`, Argo CD's metrics endpoints. Value depends on the app owners wanting the
data in Kibana; enable per request rather than by default.

## 6. System module — not recommended

Host-level CPU load, process lists and filesystem usage require mounting `/proc`, `/sys` and the host
root, running as root, and usually host networking — likely blocked by cluster policy, and the
kubelet metrics we already collect cover node CPU, memory, filesystem and network.

## Suggested order

1. **Stack self-monitoring** — no new pods or images; protects the monitoring platform itself.
2. **Kubernetes state + events** — after checking `ama-metrics-ksm`.
3. **Istio gateway + istiod**.
4. Azure load balancer (and ACR) metric sets.

Before each: run the storage check
(`GET _cat/indices/*beat*,.monitoring*?v&h=index,docs.count,store.size&s=index`) and enable one
module at a time, re-measuring daily growth.
