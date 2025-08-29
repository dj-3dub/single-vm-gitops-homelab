#!/usr/bin/env bash
set -Eeuo pipefail

# FQDNs (change if needed)
ARGOCDFQDN="${ARGOCDFQDN:-argocd.pizza}"
GRAFANAFQDN="${GRAFANAFQDN:-grafana.pizza}"
WHOAMIFQDN="${WHOAMIFQDN:-whoami.pizza}"

# 0) Pre-reqs
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
command -v helm >/dev/null 2>&1 || { echo "Helm missing"; exit 1; }
# 0) Pre-reqs
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
command -v helm >/dev/null 2>&1 || { echo "Helm missing"; exit 1; }

# 1) Argo CD
kubectl create ns argocd >/dev/null 2>&1 || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true

cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: ${ARGOCDFQDN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
YAML

# 2) kube-prometheus-stack (Grafana)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
kubectl create ns monitoring >/dev/null 2>&1 || true

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --version 65.4.0 \
  --timeout 15m --wait \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=traefik \
  --set grafana.ingress.hosts[0]="${GRAFANAFQDN}" \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.resources.requests.cpu=250m \
  --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
  --set prometheus.prometheusSpec.resources.limits.cpu=1 \
  --set prometheus.prometheusSpec.resources.limits.memory=2Gi

# 3) Loki + Promtail
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null
kubectl create ns logging >/dev/null 2>&1 || true

helm upgrade --install loki-stack grafana/loki-stack \
  -n logging --version 2.10.2 \
  --set loki.auth_enabled=false \
  --set promtail.enabled=true

# 4) Demo app: whoami
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: whoami, namespace: default }
spec:
  replicas: 1
  selector: { matchLabels: { app: whoami } }
  template:
    metadata: { labels: { app: whoami } }
    spec:
      containers:
      - name: whoami
        image: containous/whoami:v1.5.0
        ports: [ { containerPort: 80 } ]
---
apiVersion: v1
kind: Service
metadata: { name: whoami, namespace: default }
spec:
  selector: { app: whoami }
  ports: [ { name: http, port: 80, targetPort: 80 } ]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
  - host: ${WHOAMIFQDN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: whoami, port: { number: 80 } }
YAML

# 5) Output creds
echo
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<pending>"
echo
echo "Grafana admin password:"
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "<pending>"
echo
echo "Done."
