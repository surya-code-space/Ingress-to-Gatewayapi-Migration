#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  GATEWAY API DEMO — Full Prerequisites + Cluster Setup
#  Run once before the demo. Takes ~5–8 min on first run.
#
#  What this installs (nothing assumed except Docker + kubectl + brew):
#    • kind              — local K8s cluster in Docker
#    • helm              — install Envoy Gateway chart
#    • ingress2gateway   — official SIG-Network migration tool
#    • nginx-ingress     — the "before" controller
#    • Envoy Gateway     — the "after" controller
#    • Sample app        — web, api-v1, api-v2 deployments
#    • Gateway API CRDs  — standard channel v1.2.1
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "\n${CYAN}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "\n${RED}✘ FATAL: $*${NC}\n"; exit 1; }
run()  { echo -e "  ${DIM}\$ $*${NC}"; eval "$@"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="gpen-demo"

clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   Gateway API Demo — Prerequisites + Setup      ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Guard: Docker must be running ────────────────────────────────
log "Checking Docker..."
if ! docker info &>/dev/null; then
  die "Docker is not running. Open Docker Desktop and try again."
fi
ok "Docker is running"

# ── Guard: kubectl must exist ─────────────────────────────────────
log "Checking kubectl..."
command -v kubectl &>/dev/null || die "kubectl not found. Install: brew install kubectl"
ok "kubectl $(kubectl version --client 2>/dev/null | head -1)"

# ──────────────────────────────────────────────────────────────────
# PREREQUISITE 1: kind
# ──────────────────────────────────────────────────────────────────
log "PREREQ 1/3 — kind (Kubernetes in Docker)"
if command -v kind &>/dev/null; then
  ok "kind already installed: $(kind version)"
else
  echo -e "  ${DIM}Installing via Homebrew...${NC}"
  brew install kind
  ok "kind installed: $(kind version)"
fi

# ──────────────────────────────────────────────────────────────────
# PREREQUISITE 2: helm
# ──────────────────────────────────────────────────────────────────
log "PREREQ 2/3 — helm (for Envoy Gateway chart)"
if command -v helm &>/dev/null; then
  ok "helm already installed: $(helm version --short)"
else
  brew install helm
  ok "helm installed"
fi

# ──────────────────────────────────────────────────────────────────
# PREREQUISITE 3: ingress2gateway (official SIG-Network tool)
# ──────────────────────────────────────────────────────────────────
log "PREREQ 3/3 — ingress2gateway (migration tool)"
if command -v ingress2gateway &>/dev/null; then
  ok "ingress2gateway already installed"
else
  # Detect arch and download binary from GitHub releases
  ARCH="$(uname -m)"
  [[ "$ARCH" == "arm64" ]] && ARCH="arm64" || ARCH="amd64"
  I2G_VERSION="v0.3.0"
  I2G_URL="https://github.com/kubernetes-sigs/ingress2gateway/releases/download/${I2G_VERSION}/ingress2gateway_Darwin_${ARCH}.tar.gz"

  echo -e "  ${DIM}Downloading ingress2gateway ${I2G_VERSION} (${ARCH})...${NC}"
  TMP=$(mktemp -d)
  curl -sSL "$I2G_URL" -o "$TMP/i2g.tar.gz"
  tar -xzf "$TMP/i2g.tar.gz" -C "$TMP"
  sudo mv "$TMP/ingress2gateway" /usr/local/bin/ingress2gateway
  sudo chmod +x /usr/local/bin/ingress2gateway
  rm -rf "$TMP"
  ok "ingress2gateway installed: $(ingress2gateway version 2>/dev/null || echo $I2G_VERSION)"
fi

# ──────────────────────────────────────────────────────────────────
# CLUSTER: create kind cluster
# ──────────────────────────────────────────────────────────────────
log "Creating kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping"
else
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80     # nginx-ingress NodePort → host 8080
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
EOF
  ok "Cluster created"
fi

run "kubectl config use-context kind-${CLUSTER_NAME}"
ok "kubectl context → kind-${CLUSTER_NAME}"

# ──────────────────────────────────────────────────────────────────
# nginx-ingress controller (the "before" state)
# ──────────────────────────────────────────────────────────────────
log "Installing nginx-ingress controller (the 'before' state)..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml --dry-run=client -o name &>/dev/null \
  && kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo -e "  ${DIM}Waiting for nginx-ingress pod to appear...${NC}"
for i in $(seq 1 30); do
  kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null \
    | grep -q "controller" && break
  echo -ne "  ${DIM}  not yet (${i}/30)...${NC}\r"
  sleep 3
done
echo ""
echo -e "  ${DIM}Pod found — waiting for Ready...${NC}"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
ok "nginx-ingress controller ready"

# ──────────────────────────────────────────────────────────────────
# Sample application
# ──────────────────────────────────────────────────────────────────
log "Deploying sample application (web · api-v1 · api-v2)..."
kubectl apply -f "$DEMO_DIR/app/deployment.yaml"
kubectl apply -f "$DEMO_DIR/app/service.yaml"
kubectl wait --for=condition=available deployment/gpen-web deployment/gpen-api-v1 deployment/gpen-api-v2 --timeout=90s
ok "Sample app running (3 deployments, 3 services)"

# ──────────────────────────────────────────────────────────────────
# Legacy Ingress resource
# ──────────────────────────────────────────────────────────────────
log "Applying legacy nginx Ingress resource..."
kubectl apply -f "$DEMO_DIR/ingress/ingress.yaml"
ok "Ingress 'gpen-ingress' applied"

# ──────────────────────────────────────────────────────────────────
# Envoy Gateway (installs Gateway API CRDs + controller together)
# ──────────────────────────────────────────────────────────────────
log "Installing Envoy Gateway v1.3.0 via Helm..."
helm upgrade --install gpen-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.3.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --wait --timeout 3m
ok "Envoy Gateway installed and ready"

# ──────────────────────────────────────────────────────────────────
# /etc/hosts
# ──────────────────────────────────────────────────────────────────
log "Checking /etc/hosts for gpen.local..."
if grep -q "gpen\.local" /etc/hosts 2>/dev/null; then
  ok "gpen.local already in /etc/hosts"
else
  warn "gpen.local not found — add it now:"
  echo -e "\n  ${BOLD}sudo sh -c 'echo \"127.0.0.1  gpen.local\" >> /etc/hosts'${NC}\n"
  read -rp "  Run this automatically now? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    sudo sh -c 'echo "127.0.0.1  gpen.local" >> /etc/hosts'
    ok "Added gpen.local → /etc/hosts"
  fi
fi

# ──────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║          Setup Complete — Ready for Demo         ║"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  Cluster : kind-gpen-demo                        ║"
echo "  ║  Before  : nginx-ingress  → localhost:8080       ║"
echo "  ║  After   : Envoy Gateway  → localhost:9080       ║"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  Next: ./scripts/02-migrate.sh                   ║"
echo "  ║  Live monitor (separate terminal):               ║"
echo "  ║    ./scripts/02-migrate-monitor.sh               ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
