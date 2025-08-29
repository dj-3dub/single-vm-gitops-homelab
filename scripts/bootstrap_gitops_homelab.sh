#!/usr/bin/env bash
# Bootstrap a single-VM GitOps homelab on Ubuntu 24.04
# Includes:
#   - Hostname setup
#   - Static IP via netplan (set to 192.168.2.60 by default; applies automatically)
#   - Swap creation (if missing)
#   - k3s (with Traefik)
#   - Argo CD (Ingress)
#   - kube-prometheus-stack (Grafana Ingress)
#   - Loki + Promtail
#   - Demo app: whoami (Ingress)
#   - Self-signed TLS (local CA) + optional SCP export to Windows
#
# Defaults (override via env only if you need to):
#   HOSTNAME=ubuntu-argo
#   IFACE=ens33
#   STATIC_IP=192.168.2.60 CIDR=24 GATEWAY=192.168.2.1 DNS1=192.168.2.1 DNS2=1.1.1.1
#   APPLY_NETPLAN=yes
#   SWAP_SIZE=4G
#   ARGOCDFQDN=argocd.pizza GRAFANAFQDN=grafana.pizza WHOAMIFQDN=whoami.pizza
#   PROM_RETENTION=7d
#   TLS_MODE=selfsigned            # none | selfsigned
#   TLS_HOSTS="argocd.pizza,grafana.pizza,whoami.pizza"
#   TLS_SECRET_NAME=homelab-tls
#   SCP_TO_WINDOWS=no WIN_HOST=<windows-ip> WIN_USER=<win-user> WIN_PORT=22 WIN_DEST='~/Downloads/homelab-ca.crt'
#
set -Eeuo pipefail

# ---------------------------
# Config (env overrides)
# ---------------------------
HOSTNAME="${HOSTNAME:-ubuntu-argo}"
IFACE="${IFACE:-ens33}"
STATIC_IP="${STATIC_IP:-192.168.2.60}"
CIDR="${CIDR:-24}"
GATEWAY="${GATEWAY:-192.168.2.1}"
DNS1="${DNS1:-192.168.2.1}"
DNS2="${DNS2:-1.1.1.1}"
APPLY_NETPLAN="${APPLY_NETPLAN:-yes}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

ARGOCDFQDN="${ARGOCDFQDN:-argocd.pizza}"
GRAFANAFQDN="${GRAFANAFQDN:-grafana.pizza}"
WHOAMIFQDN="${WHOAMIFQDN:-whoami.pizza}"
PROM_RETENTION="${PROM_RETENTION:-7d}"
K3S_INSTALL_URL="${K3S_INSTALL_URL:-https://get.k3s.io}"
ARGOCD_MANIFEST_URL="${ARGOCD_MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

# TLS
TLS_MODE="${TLS_MODE:-selfsigned}" # none | selfsigned
TLS_HOSTS="${TLS_HOSTS:-${ARGOCDFQDN},${GRAFANAFQDN},${WHOAMIFQDN}}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-homelab-tls}"

# Export CA to Windows (optional)
SCP_TO_WINDOWS="${SCP_TO_WINDOWS:-no}"
WIN_HOST="${WIN_HOST:-}"
WIN_USER="${WIN_USER:-}"
WIN_PORT="${WIN_PORT:-22}"
WIN_DEST="${WIN_DEST:-~/Downloads/homelab-ca.crt}"

# ---------------------------
# Helpers
# ---------------------------
log() { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok()  { printf "\033[1;32m✔ %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✖ %s\033[0m\n" "$*" >&2; exit 1; }

write_file_if_changed() {
  local path="$1" tmp
  tmp="$(mktemp)"
  printf "%s" "$2" > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  install -m 0644 -D "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

# ---------------------------
# 0) Preflight, base tools
# ---------------------------
if [[ $EUID -ne 0 ]]; then die "Please run as root (sudo -i)."; fi

log "Installing base tools…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl jq ca-certificates unzip git dnsutils lsb-release gnupg openssl

# ---------------------------
# 0a) Hostname
# ---------------------------
cur_hn="$(hostnamectl --static status 2>/dev/null | awk '/Static hostname/{print $3}')"
if [[ "${cur_hn}" != "${HOSTNAME}" ]]; then
  log "Setting hostname '${HOSTNAME}'…"
  hostnamectl set-hostname "${HOSTNAME}"
  if grep -qE '^127\.0\.1\.1\s' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${HOSTNAME}" >> /etc/hosts
  fi
  ok "Hostname set."
else
  ok "Hostname already '${HOSTNAME}'."
fi

# ---------------------------
# 0b) Static IP via netplan (APPLY_NETPLAN=yes by default)
# ---------------------------
CURR_IP="$(ip -o -4 addr show dev "${IFACE:-}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "${IFACE}" ]]; then
  die "Network interface not set. Set IFACE (e.g., IFACE=ens33) and re-run."
fi

if [[ "${APPLY_NETPLAN}" == "yes" ]]; then
  log "Applying netplan for ${IFACE} → ${STATIC_IP}/${CIDR} (gw ${GATEWAY}; DNS ${DNS1},${DNS2})…"
  ts="$(date +%s)"
  mkdir -p /root/netplan.backup
  cp -av /etc/netplan /root/netplan.backup/netplan-${ts} >/dev/null 2>&1 || true
  yaml="$(cat <<YAML
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
)"
  if write_file_if_changed "/etc/netplan/01-homelab.yaml" "$yaml"; then
    log "netplan apply (SSH will drop if you're remote and IP changes)…"
    netplan generate
    netplan apply || true
    ok "Netplan applied."
  else
    ok "Netplan already up to date."
  fi
else
  warn "APPLY_NETPLAN!='yes' → skipping network config (current IP: ${CURR_IP:-unknown})."
fi

# ---------------------------
# 0c) Swap (if missing)
# ---------------------------
if swapon --show | grep -q 'partition\|file'; then
  ok "Swap already enabled."
else
  log "Creating swap file (${SWAP_SIZE})…"
  fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(( ${SWAP_SIZE%G} * 1024 ))
  chmod 600 /swapfile
  mkswap /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  swapon -a
  ok "Swap enabled."
fi

# ---------------------------
# 1) Helm & kubectl
# ---------------------------
if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm…"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else ok "Helm already installed."; fi

if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl…"
  KUBECTL_VERSION="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
  curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
else ok "kubectl already installed."; fi

# ---------------------------
# 2) k3s
# ---------------------------
if ! command -v k3s >/dev/null 2>&1; then
  log "Installing k3s (Traefik enabled)…"
  curl -sfL "${K3S_INSTALL_URL}" | sh -
else ok "k3s already installed."; fi

mkdir -p /root/.kube
cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config
export KUBECONFIG=/root/.kube/config

log "Waiting for node to be Ready…"
kubectl wait --for=condition=Ready node --all --timeout=180s || true
kubectl get nodes -o wide

# ---------------------------
# 3) Argo CD + Ingress
# ---------------------------
log "Installing Argo CD…"
kubectl create ns argocd >/dev/null 2>&1 || true
kubectl apply -n argocd -f "${ARGOCD_MANIFEST_URL}"

log "Waiting for Argo CD deployments…"
for d in argocd-server argocd-repo-server argocd-application-controller; do
  kubectl -n argocd rollout status deploy/$d --timeout=300s || true
done

log "Creating Traefik Ingress for Argo CD (${ARGOCDFQDN})…"
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

# ---------------------------
# 4) Monitoring (kube-prometheus-stack)
# ---------------------------
log "Installing kube-prometheus-stack (Grafana at ${GRAFANAFQDN})…"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
kubectl create ns monitoring >/dev/null 2>&1 || true

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 65.4.0 \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=traefik \
  --set grafana.ingress.hosts[0]="${GRAFANAFQDN}" \
  --set prometheus.prometheusSpec.retention="${PROM_RETENTION}" \
  --set prometheus.prometheusSpec.resources.requests.cpu=500m \
  --set prometheus.prometheusSpec.resources.requests.memory=2Gi \
  --set prometheus.prometheusSpec.resources.limits.cpu=2 \
  --set prometheus.prometheusSpec.resources.limits.memory=4Gi

# ---------------------------
# 5) Loki + Promtail
# ---------------------------
log "Installing Loki stack (with Promtail)…"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null
kubectl create ns logging >/dev/null 2>&1 || true

helm upgrade --install loki-stack grafana/loki-stack \
  --namespace logging \
  --version 2.10.2 \
  --set loki.auth_enabled=false \
  --set promtail.enabled=true

# ---------------------------
# 5.5) Self-signed TLS (optional): local CA -> SAN cert for all hosts
# ---------------------------
if [[ "${TLS_MODE}" == "selfsigned" ]]; then
  log "Generating local CA + SAN cert for: ${TLS_HOSTS}"
  mkdir -p /root/tls && cd /root/tls

  if [[ ! -s homelab-ca.key || ! -s homelab-ca.crt ]]; then
    openssl genrsa -out homelab-ca.key 4096
    openssl req -x509 -new -nodes -key homelab-ca.key -sha256 -days 3650 -out homelab-ca.crt -subj "/CN=Homelab Local CA"
    ok "Local CA at /root/tls/homelab-ca.crt (import to client trust stores)."
  else
    ok "Local CA already present."
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

  # Patch Ingresses to TLS
  for pair in "argocd:${ARGOCDFQDN}:argocd" "kube-prometheus-stack-grafana:${GRAFANAFQDN}:monitoring" "whoami:${WHOAMIFQDN}:default"; do
    name="${pair%%:*}"; rest="${pair#*:}"; host="${rest%%:*}"; ns="${rest##*:}"
    kubectl -n "$ns" annotate ingress "$name" traefik.ingress.kubernetes.io/router.entrypoints=websecure --overwrite || true
    kubectl -n "$ns" annotate ingress "$name" traefik.ingress.kubernetes.io/router.tls=true --overwrite || true
    kubectl -n "$ns" patch ingress "$name" --type='merge' -p "{\"spec\":{\"tls\":[{\"hosts\":[\"$host\"],\"secretName\":\"${TLS_SECRET_NAME}\"}]}} " || true
  done

  # Optional redirect middleware (if Traefik CRDs present; otherwise harmless)
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

  # Optional: export CA to Windows via SCP
  if [[ "${SCP_TO_WINDOWS}" == "yes" ]]; then
    log "Exporting local CA to Windows via SCP…"
    if ! command -v scp >/dev/null 2>&1; then apt-get install -y openssh-client >/dev/null; fi
    if [[ -z "${WIN_HOST}" || -z "${WIN_USER}" ]]; then
      warn "WIN_HOST and WIN_USER must be set. Skipping SCP."
    else
      scp -P "${WIN_PORT}" /root/tls/homelab-ca.crt "${WIN_USER}@${WIN_HOST}:${WIN_DEST}" \
        && ok "CA exported to ${WIN_USER}@${WIN_HOST}:${WIN_DEST}" \
        || warn "SCP export failed. Check Windows OpenSSH Server, credentials, firewall."
    fi
  fi

  ok "Self-signed TLS configured. Import /root/tls/homelab-ca.crt into client trust stores."
else
  warn "TLS_MODE='${TLS_MODE}' → skipping TLS (using HTTP)."
fi

# ---------------------------
# 6) Demo app (whoami) + Ingress
# ---------------------------
log "Deploying demo app 'whoami' at ${WHOAMIFQDN}…"
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: { app: whoami }
  template:
    metadata:
      labels: { app: whoami }
    spec:
      containers:
        - name: whoami
          image: containous/whoami:v1.5.0
          ports:
            - containerPort: 80
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "256Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default
spec:
  selector: { app: whoami }
  ports:
    - name: http
      port: 80
      targetPort: 80
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
              service:
                name: whoami
                port:
                  number: 80
YAML

# ---------------------------
# 7) Credentials & DNS checks
# ---------------------------
log "Fetching Argo CD admin password…"
ARGO_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
[[ -n "${ARGO_PW}" ]] && ok "Argo CD admin initial password: ${ARGO_PW}" || warn "Argo CD secret not ready; try in ~30s."

log "Fetching Grafana admin password…"
GRAFANA_PW="$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
[[ -n "${GRAFANA_PW}" ]] && ok "Grafana admin password: ${GRAFANA_PW}" || warn "Grafana secret not ready; try later."

log "DNS sanity checks:"
for host in "$ARGOCDFQDN" "$GRAFANAFQDN" "$WHOAMIFQDN"; do
  if ! getent hosts "$host" >/dev/null 2>&1; then
    warn "Host '$host' does not resolve on this VM. Ensure Pi-hole A-record → this VM IP."
  else
    ip_res="$(getent hosts "$host" | awk '{print $1}' | paste -sd ',' -)"
    ok "$host resolves to: $ip_res"
  fi
done

# ---------------------------
# 8) Summary
# ---------------------------
NEW_HN="$(hostnamectl --static status 2>/dev/null | awk '/Static hostname/{print $3}')"
cat <<EOF

====================================================================
 GitOps Homelab — Bootstrap Complete
====================================================================
Hostname:     ${NEW_HN:-<unchanged>}
Interface:    ${IFACE:-<unknown>}
Static IP:    ${STATIC_IP} (previous: ${CURR_IP:-<unknown>})
Swap:         $(swapon --show | awk 'NR==2 {print $1, $3}' || echo "see: swapon --show")

Argo CD:      http://${ARGOCDFQDN}     (user: admin; password: ${ARGO_PW:-<pending>})
Grafana:      http://${GRAFANAFQDN}    (user: admin; password: ${GRAFANA_PW:-<pending>})
whoami app:   http://${WHOAMIFQDN}

Next steps:
  1) In Pi-hole, ensure A-records for:
       - ${ARGOCDFQDN}
       - ${GRAFANAFQDN}
       - ${WHOAMIFQDN}
     → point to ${STATIC_IP}.
  2) In Grafana, add Loki datasource if not auto-added:
       URL: http://loki.logging.svc.cluster.local:3100
  3) Optionally convert to full GitOps by creating Argo CD Applications that reference a Git repo.

Useful commands:
  kubectl get pods -A
  kubectl get ingress -A
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

Re-run safe:
  - Netplan is idempotent (applies only if content changes)
  - helm upgrade --install + kubectl apply are idempotent
====================================================================
EOF
