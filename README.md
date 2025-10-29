# Single‑VM GitOps Homelab  
One VM to rule them all 🧙‍♂️ — deploy a full GitOps homelab on Ubuntu with K3s, Argo CD, Helm, monitoring & logging.

## ☕ Overview  
This project turns a single Ubuntu VM into a fully functional homelab environment, leveraging modern DevOps tools and GitOps workflows. With minimal setup you’ll have:  
- A lightweight Kubernetes cluster via K3s  
- Continuous delivery via Argo CD  
- Monitoring & metrics via kube‑prometheus‑stack (Prometheus + Grafana)  
- Log aggregation via Loki/Promtail  
- Ingress routing via Traefik, with friendly hostnames (e.g., `argocd.pizza`, `grafana.pizza`, `whoami.pizza`)  

Ideal for experimenting with infrastructure, self‑hosting, Kubernetes, observability, and GitOps — on one machine.

## 🧱 Architecture  
![Homelab Architecture (Single‑VM K3s)](docs/homelab.svg)  

The setup includes a single Ubuntu VM (static IP), running:  
- K3s single‑node cluster  
- Argo CD for managing app deployments  
- Helm charts for monitoring (via kube‑prometheus‑stack) and logging (via loki‑stack)  
- Traefik as the ingress controller  
- Scripts to bootstrap everything quickly  

## ⚙️ Stack Components  
- **K3s** – lightweight Kubernetes distribution for single‑node cluster  
- **Argo CD** – GitOps continuous delivery tool  
- **Helm** – package management for Kubernetes  
- **kube‑prometheus‑stack** – Prometheus + Grafana for metrics & dashboards  
- **loki‑stack** – Loki + Promtail for logs aggregation and querying  
- **Traefik** – ingress controller to route external traffic to services  
- **Bash + Python** – automation scripts and health checks  

## 🚀 Quick Start (on the VM)  
```bash
sudo -i
apt-get update -y && apt-get install -y git curl
git clone https://github.com/dj‑3dub/single‑vm‑gitops‑homelab.git homelab
cd homelab
bash scripts/fix-swap.sh          # optional: if /swap.img exists
bash scripts/one-shot-homelab.sh  # network, K3s, Argo CD, Helm installs, whoami, optional TLS
```

Once complete, access:  
- `argocd.pizza` → Argo CD UI  
- `grafana.pizza` → Grafana UI  
- `whoami.pizza` → demo “whoami” app  
> Want your own domain? Just update the FQDNs in the `scripts/env` and your DNS (e.g., via Pi‑hole or `/etc/hosts`) accordingly.

## 🔧 Customization & Extensions  
- Change the `.pizza` domain to your personal domain or local TLD  
- Extend the GitOps repo with additional Helm charts or Kubernetes manifests  
- Add other observability tools (e.g., Loki alerts, Grafana Loki dashboards)  
- Experiment with backup/restore, storage classes, single‑node high availability  
- Use this as a base for self‑hosting webapps, home automation, or lab practice  

## 🤝 Contributing  
Feel free to fork, adapt and extend this stack for your own homelab. Contributions (ideas, improvements, scripts) are welcome. Please open issues or PRs.

## 🛡️ License  
MIT License – see [LICENSE](LICENSE) for details.

## ❤️ About Me  
Built by **Tim Heverin** — infrastructure tinkerer, cloud & homelab enthusiast.  
Check out my other projects: [Pizza Stack](https://github.com/dj-3dub/pizza-stack), [Monitoring Stack](https://github.com/dj-3dub/monitoring-stack), [Homelab SSO](https://github.com/dj-3dub/homelab-sso).
