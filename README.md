*k3s + Argo CD + **Helm** (kube-prometheus-stack, Loki/Promtail) + Traefik — on one Ubuntu VM*

This repo contains my one-VM **k3s + Argo CD + Grafana/Prometheus + Loki/Promtail** stack, with scripts and a Python health check.

## ✨ What’s included
- Single-node **k3s** cluster (static IP: `192.168.2.60`, NIC: `ens33`, hostname: `ubuntu-argo`)
- **Ingress apps**
  - `argocd.pizza` → Argo CD UI
  - `grafana.pizza` → Grafana UI
  - `whoami.pizza` → demo app
- **Metrics & dashboards** via **kube-prometheus-stack** (Helm)
- **Cluster logs** via **loki-stack** (Helm)

> Don’t like “.pizza”? Change the FQDNs in the scripts/env and your DNS (Pi-hole or `/etc/hosts`).

<p align="center">
  <img src="docs/homelab.svg" alt="Homelab Architecture (Single-VM k3s)" width="820">
</p>

---

## 🚀 Quick start (on the VM)

```bash
sudo -i
apt-get update -y && apt-get install -y git curl
git clone https://github.com/dj-3dub/single-vm-gitops-homelab.git homelab
cd homelab
bash scripts/fix-swap.sh          # optional: if /swap.img exists
bash scripts/one-shot-homelab.sh  # network, k3s, Argo CD, Helm installs, whoami, optional TLS
