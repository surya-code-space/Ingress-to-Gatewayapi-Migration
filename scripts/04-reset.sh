#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  RESOURCE RESET — deletes only what we created inside the cluster
#  Keeps: kind cluster, nginx-ingress controller, Envoy Gateway
#  Removes: app, Ingress, Gateway, HTTPRoute, backup files
#  Use this to re-run the demo without rebuilding the cluster.
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}✘ $*${NC}"; }
chk()  { echo -e "  ${CYAN}▶ $*${NC}"; }

echo -e "\n${BOLD}${CYAN}  ── Resource Reset (cluster stays up) ──────────────────${NC}\n"

# Stop port-forwards
chk "Stopping port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
ok "port-forwards stopped"

# Delete Gateway API resources
chk "Removing Gateway API resources..."
kubectl delete httproute gpen-route        --ignore-not-found 2>/dev/null
kubectl delete gateway gpen-gateway       --ignore-not-found 2>/dev/null
kubectl delete gatewayclass gpen-gateway  --ignore-not-found 2>/dev/null
ok "HTTPRoute, Gateway, GatewayClass removed"

# Delete legacy Ingress
chk "Removing Ingress..."
kubectl delete ingress gpen-ingress        --ignore-not-found 2>/dev/null
ok "Ingress removed"

# Delete sample app (default namespace)
chk "Removing sample app..."
kubectl delete deployment gpen-web gpen-api-v1 gpen-api-v2 --ignore-not-found 2>/dev/null
kubectl delete service gpen-web gpen-api-v1 gpen-api-v2    --ignore-not-found 2>/dev/null
ok "Deployments + Services removed"

# Delete staging namespace (cross-namespace demo)
if kubectl get namespace staging &>/dev/null; then
  chk "Removing staging namespace..."
  kubectl delete namespace staging --ignore-not-found 2>/dev/null
  ok "staging namespace removed"
fi

# Remove generated files
chk "Removing generated files..."
rm -f "$DEMO_DIR/ingress-backup.yaml"
rm -f "$DEMO_DIR/gateway/ingress2gateway-converted.yaml"
ok "ingress-backup.yaml + ingress2gateway-converted.yaml removed"

# Re-apply sample app + Ingress so cluster is back to "before" state
echo -e "\n  Re-deploying sample app + legacy Ingress (back to 'before' state)..."
kubectl apply -f "$DEMO_DIR/app/deployment.yaml" 2>/dev/null
kubectl apply -f "$DEMO_DIR/app/service.yaml"    2>/dev/null
kubectl apply -f "$DEMO_DIR/ingress/ingress.yaml" 2>/dev/null
kubectl wait --for=condition=available deployment/gpen-web deployment/gpen-api-v1 deployment/gpen-api-v2 --timeout=60s 2>/dev/null
ok "app + Ingress restored"

# ══════════════════════════════════════════════════════════════════
#  PRE-DEMO STATUS PANEL
# ══════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║           ✔  Reset Complete — Pre-Demo Status                   ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 1. Installed tools ───────────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ INSTALLED TOOLS ─────────────────────────────────────────────┐${NC}"
KIND_VER=$(kind version 2>/dev/null || echo "not found")
HELM_VER=$(helm version --short 2>/dev/null || echo "not found")
I2G_VER=$(command -v ingress2gateway &>/dev/null && echo "installed (v0.3.0)" || echo "not found")
KCL_VER=$(kubectl version --client 2>/dev/null | head -1 || echo "unknown")
printf "  ${DIM}%-22s${NC} %s\n" "kind:"              "$KIND_VER"
printf "  ${DIM}%-22s${NC} %s\n" "kubectl:"           "$KCL_VER"
printf "  ${DIM}%-22s${NC} %s\n" "helm:"              "$HELM_VER"
printf "  ${DIM}%-22s${NC} %s\n" "ingress2gateway:"   "$I2G_VER"
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 2. Cluster ───────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ CLUSTER ──────────────────────────────────────────────────────┐${NC}"
CTX=$(kubectl config current-context 2>/dev/null || echo "none")
NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1" → "$2}' || echo "unavailable")
printf "  ${DIM}%-22s${NC} %s\n" "context:"  "$CTX"
printf "  ${DIM}%-22s${NC} %s\n" "node:"     "$NODE_STATUS"
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 3. Controllers ───────────────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ CONTROLLERS ──────────────────────────────────────────────────┐${NC}"
NGINX_STATUS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
  --no-headers 2>/dev/null | awk '{print $1" → "$3}' | head -1 || echo "not found")
EG_STATUS=$(kubectl get pods -n envoy-gateway-system --no-headers 2>/dev/null \
  | awk '{print $1" → "$3}' | head -3 | tr '\n' '  ' || echo "not found")
printf "  ${DIM}%-22s${NC} %s\n" "nginx-ingress:"     "$NGINX_STATUS"
printf "  ${DIM}%-22s${NC} %s\n" "envoy-gateway:"     "$EG_STATUS"
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 4. Sample app ────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ SAMPLE APPLICATION (default namespace) ───────────────────────┐${NC}"
kubectl get deployments gpen-web gpen-api-v1 gpen-api-v2 --no-headers 2>/dev/null \
  | awk '{printf "  \033[2m%-22s\033[0m %s/%s ready\n", $1":", $2, $3}' \
  || warn "deployments not found"
echo ""
kubectl get services gpen-web gpen-api-v1 gpen-api-v2 --no-headers 2>/dev/null \
  | awk '{printf "  \033[2msvc/%-18s\033[0m ClusterIP %s  port %s\n", $1, $3, $5}' \
  || warn "services not found"
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 5. Ingress ───────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ LEGACY INGRESS (the 'before' state) ──────────────────────────┐${NC}"
kubectl get ingress gpen-ingress --no-headers 2>/dev/null \
  | awk '{printf "  \033[2m%-22s\033[0m class=%-10s host=%s\n", $1, $3, $4}' \
  || warn "gpen-ingress not found"
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 6. Network / port access ────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ NETWORK ACCESS ──────────────────────────────────────────────┐${NC}"
HOSTS_OK=$(grep -q "gpen\.local" /etc/hosts 2>/dev/null && echo "${GREEN}✔ present${NC}" || echo "${YELLOW}⚠ missing — add: 127.0.0.1  gpen.local${NC}")
printf "  ${DIM}%-22s${NC} " "/etc/hosts gpen.local:"; echo -e "$HOSTS_OK"
printf "  ${DIM}%-22s${NC} %s\n" "nginx-ingress port:"  "localhost:8080  (before path)"
printf "  ${DIM}%-22s${NC} %s\n" "envoy-gateway port:"  "localhost:9080  (after path — needs port-forward during demo)"
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 7. Quick health check ────────────────────────────────────────
echo -e "${BOLD}${BLUE}  ┌─ QUICK HEALTH CHECK ───────────────────────────────────────────┐${NC}"
# Start a temp port-forward to test nginx
pkill -f "port-forward.*ingress-nginx" 2>/dev/null || true
sleep 0.5
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 &>/dev/null &
PF_PID=$!
sleep 2
NGINX_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: gpen.local" \
  --connect-timeout 3 http://localhost:8080/ 2>/dev/null || echo "ERR")
kill $PF_PID 2>/dev/null || true
if [[ "$NGINX_HTTP" == "200" ]]; then
  ok "nginx-ingress → gpen.local:8080 → HTTP $NGINX_HTTP"
else
  warn "nginx-ingress → gpen.local:8080 → HTTP $NGINX_HTTP (may need a moment to settle)"
fi
echo -e "${BOLD}${BLUE}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ── 8. What's next ───────────────────────────────────────────────
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║  Everything is in the 'BEFORE' state — ready to demo!            ║"
echo "  ║                                                                  ║"
echo "  ║  Demo order:                                                     ║"
echo "  ║    Terminal 1 → ./scripts/02-migrate.sh                          ║"
echo "  ║    Terminal 2 → ./scripts/02-migrate-monitor.sh   (Phase 3+)     ║"
echo "  ║    Terminal 1 → ./scripts/03-enhance.sh           (after cutover)║"
echo "  ║    Terminal 2 → ./scripts/03-enhance-monitor.sh  (Phase 1+)      ║"
echo "  ║                                                                  ║"
echo "  ║  To re-run this status panel anytime: ./scripts/04-reset.sh      ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
