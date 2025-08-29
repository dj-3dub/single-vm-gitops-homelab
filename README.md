This repo contains my one-VM k3s + Argo CD + Grafana/Prometheus + Loki/Promtail stack, with scripts and a Python health check.
## ✨ What’s included

- Single-node **k3s** cluster (static IP: `192.168.2.60`, NIC: `ens33`, hostname: `ubuntu-argo`)
- Ingress apps:
  - `argocd.pizza` → Argo CD UI
  - `grafana.pizza` → Grafana UI
  - `whoami.pizza` → demo app
- **Metrics & dashboards** via `kube-prometheus-stack` (Helm)
- **Cluster logs** via `loki-stack` (Helm)

> Don’t like “.pizza”? Change the FQDNs in the scripts/env and your DNS (Pi-hole or `/etc/hosts`).
## ✨ What’s included

- Single-node **k3s** cluster (static IP: `192.168.2.60`, NIC: `ens33`, hostname: `ubuntu-argo`)
- Ingress apps:
  - `argocd.pizza` → Argo CD UI
  - `grafana.pizza` → Grafana UI
  - `whoami.pizza` → demo app
- **Metrics & dashboards** via `kube-prometheus-stack` (Helm)
- **Cluster logs** via `loki-stack` (Helm)

> Don’t like “.pizza”? Change the FQDNs in the scripts/env and your DNS (Pi-hole or `/etc/hosts`).
