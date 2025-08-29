#!/usr/bin/env bash
# One-shot Homelab Bootstrap (Ubuntu 24.04, single VM)
# - Forces static IP 192.168.2.60 on ens33 (disables cloud-init DHCP)
# - Sets hostname ubuntu-argo
# - Installs/repairs k3s bound to 192.168.2.60 + ens33
# - Installs kubectl & Helm
# - Argo CD + Ingress (argocd.pizza)
# - kube-prometheus-stack + Grafana Ingress (grafana.pizza)
# - Loki + Promtail
# - whoami demo + Ingress (whoami.pizza)
# - Self-signed TLS for all hosts (optional, default: enabled)
# ------------------------------------------------------------------

set -Eeuo pipefail

# ---------- Config (defaults — change if needed) ----------
HOSTNAME="${HOSTNAME:-ubuntu-argo}"
IFACE="${IFACE:-ens33}"
STATIC_IP="${STATIC_IP:-192.168.2.60}"
CIDR="${CIDR:-24}"
GATEWAY="${GATEWAY:-192.168.2.1}"
DNS1="${DNS1:-192.168.2.1}"
DNS2="${DNS2:-1.1.1.1}"

ARGOCDFQDN="${ARGOCDFQDN:-argocd.pizza}"
GRAFANAFQDN="${GRAFANAFQDN:-grafana.pizza}"
WHOAMIFQDN="${WHOAMIFQDN:-whoami.pizza}"

TLS_MODE="${TLS_MODE:-selfsigned}"  # selfsigned | none
TLS_SECRET_NAME="${TLS_SECRET_NAME:-homelab-tls}"
TLS_HOSTS="${TLS_HOSTS:-${ARGOCDFQDN},${GRAFANAFQDN},${WHOAMIFQDN}}"

PROM_RETENTION="${PROM_RETENTION:-7d}"
K3S_INSTALL_URL="${K3S_INSTALL_URL:-https://get.k3s.io}"
ARGOCD_MANIFEST_URL="${ARGOCD_MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

# ---------- Helpers ----------
log(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok(){  printf "\033[1;32m✔ %s\033[0m\n" "$*"; }
warn(){printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
die(){ printf "\033[1;31m✖ %s\033[0m\n" "$*" >&2; exit 1; }

retry(){ # retry <times> <sleep> -- cmd...
  local -i tries=$1; shift; local -i wait=$1; shift
  until "$@"; do ((tries--)) || return 1; sleep "$wait"; done
}

# ---------- Root + base tools ----------
(( EUID == 0 )) || die "Run as root (sudo -i)."
log "Installing base tools…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl jq ca-certificates unzip git dnsutils lsb-release gnupg openssl \
  iproute2 net-tools

# ---------- Hostname ----------
cur_hn="$(hostnamectl --static 2>/dev/null | awk '/Static hostname/{print $3}')"
if [[ "$cur_hn" != "$HOSTNAME" ]]; then
  log "Setting hostname → $HOSTNAME"
  hostnamectl set-hostname "$HOSTNAME"
  if grep -qE '^127\.0\.1\.1\s' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${HOSTNAME}" >> /etc/hosts
  fi
  ok "Hostname set."
else ok "Hostname already $HOSTNAME."; fi

# ---------- Networking: force ONLY 192.168.2.60 on ens33 ----------
log "Configuring netplan → ${STATIC_IP}/${CIDR} on ${IFACE} (gw ${GATEWAY}; DNS ${DNS1},${DNS2})"
mkdir -p /etc/cloud/cloud.cfg.d
printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# backup any existing netplan
mkdir -p /root/netplan.backup
cp -av /etc/netplan /root/netplan.backup/netplan-$(date +%s) >/dev/null 2>&1 || true

# remove/disable cloud-init netplan
[ -f /etc/netplan/50-cloud-init.yaml ] && mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak

# install a late netplan that wins any merge
cat >/etc/netplan/99-homelab.yaml <<YAML
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${STATIC_IP}/${CIDR}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS1}, ${DNS2}]
YAML

chown root:root /etc/netplan/*.yaml
chmod 600 /etc/netplan/*.yaml
chmod 755 /etc/netplan

netplan generate
netplan apply || true

# kill any lingering .50
if ip -4 addr show dev "${IFACE}" | grep -q '192\.168\.2\.50/'; then
  ip addr del 192.168.2.50/24 dev "${IFACE}" || true
fi

ok "Current IPs on ${IFACE}:"
ip -4 addr show dev "${IFACE}" | sed -n 's/ *inet /  - /p'

# ---------- Swap (if missing) ----------
if ! swapon --show | awk 'NR>1{exit 0} END{exit 1}'; then
  log "Enabling 4G swap…"
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile && mkswap /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon -a
fi

# ---------- Helm & kubectl ----------
if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm…"; curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl…"
  KVER="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
  curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  install -m0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
fi

# ---------- k3s: install/repair and pin to IP/NIC ----------
mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/config.yaml <<EOF
node-name: ${HOSTNAME}
node-ip: ${STATIC_IP}
flannel-iface: ${IFACE}
tls-san:
  - 127.0.0.1
  - ${STATIC_IP}
  - ${HOSTNAME}
EOF

if ! command -v k3s >/dev/null 2>&1; then
  log "Installing k3s (server)…"
  curl -sfL "${K3S_INSTALL_URL}" | INSTALL_K3S_EXEC="server" sh -
else
  log "Restarting existing k3s with pinned config…"
  systemctl restart k3s
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log "Waiting for Kubernetes API to become ready…"
if ! retry 30 5 kubectl get --raw='/readyz' >/dev/null 2>&1; then
  warn "k3s still not ready; performing clean reinstall…"
  /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
  rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
  mkdir -p /etc/rancher/k3s && cat >/etc/rancher/k3s/config.yaml <<EOF
node-name: ${HOSTNAME}
node-ip: ${STATIC_IP}
flannel-iface: ${IFACE}
tls-san:
  - 127.0.0.1
  - ${STATIC_IP}
  - ${HOSTNAME}
EOF
  curl -sfL "${K3S_INSTALL_URL}" | INSTALL_K3S_EXEC="server" sh -
  retry 30 5 kubectl get --raw='/readyz' >/dev/null 2>&1 || die "k3s API failed to become ready."
fi
ok "Kubernetes API is ready."
kubectl wait --for=condition=Ready node --all --timeout=180s || true
kubectl get nodes -o wide || true

# ---------- Argo CD ----------
log "Installing Argo CD…"
kubectl create ns argocd >/dev/null 2>&1 || true
kubectl apply -n argocd -f "${ARGOCD_MANIFEST_URL}"

retry 30 5 kubectl -n argocd get deploy argocd-server >/dev/null 2>&1 || warn "ArgoCD may still be pulling images."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true

# Ingress for Argo CD
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

# ---------- Monitoring (kube-prometheus-stack) ----------
log "Installing kube-prometheus-stack (Grafana at ${GRAFANAFQDN})…"
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
  --set prometheus.prometheusSpec.retention="${PROM_RETENTION}" \
  --set prometheus.prometheusSpec.resources.requests.cpu=250m \
  --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
  --set prometheus.prometheusSpec.resources.limits.cpu=1 \
  --set prometheus.prometheusSpec.resources.limits.memory=2Gi

# ---------- Loki + Promtail ----------
log "Installing Loki + Promtail…"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null
kubectl create ns logging >/dev/null 2>&1 || true

helm upgrade --install loki-stack grafana/loki-stack \
  -n logging --version 2.10.2 \
  --set loki.auth_enabled=false \
  --set promtail.enabled=true

# ---------- Self-signed TLS (optional) ----------
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  log "Generating local CA + SAN cert for: ${TLS_HOSTS}"
  mkdir -p /root/tls && cd /root/tls

  if [[ ! -s homelab-ca.key || ! -s homelab-ca.crt ]]; then
    openssl genrsa -out homelab-ca.key 4096
    openssl req -x509 -new -nodes -key homelab-ca.key -sha256 -days 3650 -out homelab-ca.crt -subj "/CN=Homelab Local CA"
    ok "Local CA at /root/tls/homelab-ca.crt"
  fi

  IFS=',' read -r -a _hosts <<< "${TLS_HOSTS}"
  san_list=$(printf 'DNS:%s,' "${_hosts[@]}" | sed 's/,$//')
  openssl genrsa -out homelab-tls.key 2048
  openssl req -new -key homelab-tls.key -subj "/CN=${_hosts[0]}" -addext "subjectAltName=${san_list}" -out homelab-tls.csr
  printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n" "${san_list}" > v3.ext
  openssl x509 -req -in homelab-tls.csr -CA homelab-ca.crt -CAkey homelab-ca.key -CAcreateserial -out homelab-tls.crt -days 825 -sha256 -extfile v3.ext

  for ns in argocd monitoring default; do
    kubectl -n "$ns" create secret tls "${TLS_SECRET_NAME}" --cert=/root/tls/homelab-tls.crt --key=/root/tls/homelab-tls.key --dry-run=client -o yaml | kubectl apply -f -
  done

  # Patch ingresses for TLS + add HTTP->HTTPS redirect (Traefik CRDs may or may not exist; ignore failures)
  for pair in "argocd:${ARGOCDFQDN}:argocd" "kube-prometheus-stack-grafana:${GRAFANAFQDN}:monitoring" "whoami:${WHOAMIFQDN}:default"; do
    name="${pair%%:*}"; rest="${pair#*:}"; host="${rest%%:*}"; ns="${rest##*:}"
    kubectl -n "$ns" annotate ingress "$name" traefik.ingress.kubernetes.io/router.entrypoints=websecure --overwrite || true
    kubectl -n "$ns" annotate ingress "$name" traefik.ingress.kubernetes.io/router.tls=true --overwrite || true
    kubectl -n "$ns" patch ingress "$name" --type='merge' -p "{\"spec\":{\"tls\":[{\"hosts\":[\"$host\"],\"secretName\":\"${TLS_SECRET_NAME}\"}]}} " || true
  done

  for ns in argocd monitoring default; do
    cat <<MW | kubectl apply -n "$ns" -f - >/dev/null 2>&1 || true
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
MW
  done
  for pair in "argocd:argocd" "kube-prometheus-stack-grafana:monitoring" "whoami:default"; do
    name="${pair%%:*}"; ns="${pair##*:}"
    kubectl -n "$ns" annotate ingress "$name" traefik.ingress.kubernetes.io/router.entrypoints=web,websecure --overwrite >/dev/null 2>&1 || true
    kubectl -n "$ns" annotate ingress "$name" traefik.ingress.kubernetes.io/router.middlewares="$ns-redirect-https@kubernetescrd" --overwrite >/dev/null 2>&1 || true
  done
  ok "Self-signed TLS configured. Import /root/tls/homelab-ca.crt into clients."
else
  warn "TLS disabled (TLS_MODE=${TLS_MODE}). Using HTTP."
fi

# ---------- Demo app: whoami ----------
log "Deploying whoami → ${WHOAMIFQDN}"
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: default
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
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "256Mi" }
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

# ---------- Credentials & summary ----------
ARGO_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
GRAFANA_PW="$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"

echo ""
echo "===================================================================="
echo " Homelab Bootstrap — COMPLETE"
echo "===================================================================="
echo "Hostname:   ${HOSTNAME}"
echo "IP/NIC:     ${STATIC_IP} on ${IFACE}"
echo "Argo CD:    http${TLS_MODE:+s}://${ARGOCDFQDN}   (admin / ${ARGO_PW:-<pending>})"
echo "Grafana:    http${TLS_MODE:+s}://${GRAFANAFQDN}  (admin / ${GRAFANA_PW:-<pending>})"
echo "whoami:     http${TLS_MODE:+s}://${WHOAMIFQDN}"
echo "TLS CA:     /root/tls/homelab-ca.crt  (import to trust for green padlock)"
echo "Next:       Ensure Pi-hole A-records point these names to ${STATIC_IP}"
echo "===================================================================="
