#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  GATEWAY API DEMO — Enterprise Migration with ingress2gateway
#
#  Strategy: Zero-downtime parallel-run migration
#
#  Phase 0  Pre-flight   — audit, backup, dry-run conversion
#  Phase 1  Infrastructure — GatewayClass + Gateway (platform team)
#  Phase 2  Convert       — ingress2gateway generates HTTPRoutes
#  Phase 3  Parallel run  — BOTH nginx AND Envoy serve traffic
#  Phase 4  Validate      — automated health comparison
#  Phase 5  Cutover       — delete Ingress, full switch to Gateway API
#  Phase 6  Canary        — traffic split demo (bonus)
#  Rollback available at every phase
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
NGINX_PORT=8080
EG_PORT=9080
BACKUP_FILE="$DEMO_DIR/ingress-backup.yaml"

# ── Helpers ───────────────────────────────────────────────────────
banner() {
  clear
  echo -e "\n${BOLD}${CYAN}  ══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${CYAN}  ══════════════════════════════════════════════════${NC}\n"
}
phase()  { echo -e "\n${BOLD}${BLUE}┌─ PHASE $1: $2 ─────────────────────────────────${NC}"; }
step()   { echo -e "\n${YELLOW}  ▶ $1${NC}"; }
run()    { echo -e "  ${DIM}\$ $*${NC}"; eval "$@"; echo ""; }
ok()     { echo -e "  ${GREEN}✔ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠ $1${NC}"; }
err()    { echo -e "  ${RED}✘ $1${NC}"; }
pause()  { echo -e "\n${DIM}  [ Press ENTER to continue → ]${NC}"; read -r; }
confirm() {
  echo -e "\n  ${BOLD}${YELLOW}$1 [y/N]${NC} "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

start_pf() {
  local name=$1 ns=$2 svc=$3 local_port=$4 svc_port=$5
  pkill -f "port-forward.*$svc" 2>/dev/null || true
  sleep 0.5
  kubectl port-forward -n "$ns" "$svc" "${local_port}:${svc_port}" &>/dev/null &
  sleep 1.5
  ok "$name → http://gpen.local:$local_port"
}

stop_pf() { pkill -f "kubectl port-forward" 2>/dev/null || true; }

check_prereqs() {
  local missing=0
  for cmd in kind kubectl helm ingress2gateway; do
    command -v "$cmd" &>/dev/null || { err "$cmd not found — run setup.sh first"; missing=1; }
  done
  [[ $missing -eq 1 ]] && exit 1
  kubectl config current-context | grep -q "gpen-demo" || {
    err "kubectl context is not 'kind-gpen-demo' — run: kubectl config use-context kind-gpen-demo"
    exit 1
  }
}

# ════════════════════════════════════════════════════════════════
banner "Gateway API — Enterprise Migration Demo"
# ════════════════════════════════════════════════════════════════

check_prereqs

# ════════════════════════════════════════════════════════════════
phase 0 "PRE-FLIGHT — Audit & Backup"
# ════════════════════════════════════════════════════════════════
step "Cluster overview"
run "kubectl get nodes -o wide"
run "kubectl get pods,svc,ingress -o wide"

step "Backup all existing Ingress resources (rollback anchor)"
kubectl get ingress -A -o yaml > "$BACKUP_FILE"
ok "Backup saved → $BACKUP_FILE"
run "kubectl get ingress -A"

step "Preview ingress2gateway conversion (DRY RUN — nothing applied)"
echo -e "  ${DIM}What will ingress2gateway generate from our Ingress?${NC}\n"
ingress2gateway print --namespace=default 2>/dev/null || \
  ingress2gateway print 2>/dev/null || \
  warn "Preview unavailable (ingress2gateway may need --providers=ingress-nginx flag)"

echo -e "\n  ${BLUE}ℹ ingress2gateway reads your live Ingress resources and outputs${NC}"
echo -e "  ${BLUE}  equivalent GatewayClass + HTTPRoute YAML — no manual rewriting needed.${NC}"

pause

# ════════════════════════════════════════════════════════════════
phase 1 "INFRASTRUCTURE — GatewayClass + Gateway (platform team, once)"
# ════════════════════════════════════════════════════════════════

step "Verify Envoy Gateway is running (pre-installed in setup.sh)"
run "kubectl get pods -n envoy-gateway-system"

step "Apply GatewayClass + Gateway"
echo -e "  ${DIM}Platform team owns this — dev teams never touch it.${NC}\n"
run "cat $DEMO_DIR/gateway/01-gateway.yaml"
run "kubectl apply -f $DEMO_DIR/gateway/01-gateway.yaml"

step "Wait for Envoy proxy to spin up + Gateway to be Programmed (~2 min)..."
echo -e "  ${DIM}  Envoy Gateway creates an Envoy proxy pod + LoadBalancer service — this takes a moment.${NC}"
for i in $(seq 1 60); do
  status=$(kubectl get gateway gpen-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  svc=$(kubectl get svc -A -l "gateway.envoyproxy.io/owning-gateway-name=gpen-gateway" -o name 2>/dev/null | head -1)
  if [[ "$status" == "True" && -n "$svc" ]]; then
    ok "Gateway 'gpen-gateway' is Programmed and Envoy service is ready ✓"
    break
  fi
  echo -ne "  ${DIM}  [${i}/60] status=${status:-pending} envoy-svc=${svc:-not-created-yet}${NC}\r"
  sleep 3
done
echo ""

run "kubectl get gateway gpen-gateway -o wide"
run "kubectl get gatewayclass gpen-gateway"
pause

# ════════════════════════════════════════════════════════════════
phase 2 "CONVERT — ingress2gateway generates HTTPRoutes"
# ════════════════════════════════════════════════════════════════

step "Start nginx-ingress port-forward (BEFORE path — still live)"
start_pf "nginx-ingress" "ingress-nginx" "svc/ingress-nginx-controller" "$NGINX_PORT" 80

step "Verify Ingress path is healthy BEFORE migration"
NGINX_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: gpen.local" "http://localhost:$NGINX_PORT/" 2>/dev/null)
[[ "$NGINX_CODE" == "200" ]] && ok "nginx-ingress → 200 OK" || warn "nginx-ingress returned $NGINX_CODE"

step "Run ingress2gateway — convert Ingress → HTTPRoute YAML"
echo -e "  ${DIM}ingress2gateway reads your live Ingress and generates equivalent Gateway API resources.${NC}\n"

CONVERTED_FILE="$DEMO_DIR/gateway/ingress2gateway-converted.yaml"

# Run with --providers=ingress-nginx for nginx-ingress compatibility
LIVE_OUTPUT=$(ingress2gateway print --namespace=default --providers=ingress-nginx 2>/dev/null || true)

# Fallback: try without --providers flag (older versions)
if [[ -z "$LIVE_OUTPUT" ]]; then
  LIVE_OUTPUT=$(ingress2gateway print --namespace=default 2>/dev/null || true)
fi

if [[ -z "$LIVE_OUTPUT" ]]; then
  err "ingress2gateway produced no output — is the Ingress applied? Try: kubectl get ingress -A"
  err "Check: ingress2gateway print --namespace=default --providers=ingress-nginx"
  exit 1
fi

echo "$LIVE_OUTPUT"
echo "$LIVE_OUTPUT" > "$CONVERTED_FILE"

# ingress2gateway uses the ingressClass name ('nginx') as parentRef — patch to our gateway
sed -i '' 's/- name: nginx$/- name: gpen-gateway/' "$CONVERTED_FILE"
ok "ingress2gateway generated HTTPRoute → saved to $(basename $CONVERTED_FILE)"

echo -e "\n  ${BLUE}ℹ Review above — verify hostnames, paths, and backends match the original Ingress.${NC}"
echo -e "  ${BLUE}  After migration, layer enhancements (canary, CORS, etc.) on top of this base.${NC}"
pause

step "Apply generated HTTPRoute (Ingress still running — parallel mode)"
run "kubectl apply -f $CONVERTED_FILE"
sleep 2

run "kubectl get httproute -o wide"
run "kubectl describe httproute --all-namespaces 2>/dev/null | head -50"
pause

# ════════════════════════════════════════════════════════════════
phase 3 "PARALLEL RUN — Both paths live simultaneously"
# ════════════════════════════════════════════════════════════════

step "Start Envoy Gateway port-forward (AFTER path)"
# Wait up to 60s for the envoy service to appear
EG_SVC=""
EG_NS=""
for i in $(seq 1 20); do
  EG_SVC=$(kubectl get svc -A -l "gateway.envoyproxy.io/owning-gateway-name=gpen-gateway" -o name 2>/dev/null | head -1)
  [[ -n "$EG_SVC" ]] && break
  echo -ne "  ${DIM}  waiting for Envoy service... (${i}/20)${NC}\r"
  sleep 3
done
echo ""

if [[ -n "$EG_SVC" ]]; then
  # Resolve namespace — kubectl get svc -A returns "service/name" but not namespace inline
  EG_NS=$(kubectl get svc -A -l "gateway.envoyproxy.io/owning-gateway-name=gpen-gateway" \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
  EG_NS="${EG_NS:-envoy-gateway-system}"
  start_pf "Envoy Gateway" "$EG_NS" "$EG_SVC" "$EG_PORT" 80
else
  die "Envoy Gateway service still not found. Check: kubectl get svc -A | grep envoy"
fi

echo -e "\n  ${BOLD}${YELLOW}Both paths are LIVE simultaneously — this is zero-downtime migration:${NC}\n"

echo -e "  ${BOLD}nginx-ingress path (before):${NC}"
run "curl -s -H 'Host: gpen.local' http://localhost:$NGINX_PORT/"
run "curl -s -H 'Host: gpen.local' http://localhost:$NGINX_PORT/api"

echo -e "  ${BOLD}Gateway API / Envoy path (after):${NC}"
run "curl -s -H 'Host: gpen.local' http://localhost:$EG_PORT/"
run "curl -s -H 'Host: gpen.local' http://localhost:$EG_PORT/api"

echo -e "\n${BOLD}${YELLOW}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║  ⚡  ACTION REQUIRED — START THE MONITOR NOW                    ║"
echo "  ║                                                                  ║"
echo "  ║  Both paths are live. Open a NEW terminal and run:              ║"
echo "  ║                                                                  ║"
echo "  ║    ./scripts/02-migrate-monitor.sh                              ║"
echo "  ║                                                                  ║"
echo "  ║  The monitor compares nginx:8080 vs Envoy:9080 in real-time     ║"
echo "  ║  and logs every request — run it BEFORE pressing ENTER here.    ║"
echo "  ║                                                                  ║"
echo "  ║  Log file will be written to: /tmp/gateway-migrate-monitor-*.log║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Waiting 10 seconds for you to start the monitor...${NC}"
for i in 10 9 8 7 6 5 4 3 2 1; do
  echo -ne "  ${YELLOW}  ${i}s remaining — open new terminal → ./scripts/02-migrate-monitor.sh${NC}\r"
  sleep 1
done
echo ""
pause

# ════════════════════════════════════════════════════════════════
phase 4 "VALIDATE — Automated health comparison"
# ════════════════════════════════════════════════════════════════

step "Running 20 comparison requests (nginx vs Gateway API)..."
echo ""

PASS=0; FAIL=0; TOTAL=20
for i in $(seq 1 $TOTAL); do
  nginx_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: gpen.local" "http://localhost:$NGINX_PORT/" 2>/dev/null)
  gw_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: gpen.local" "http://localhost:$EG_PORT/" 2>/dev/null)

  if [[ "$nginx_code" == "$gw_code" && "$gw_code" == "200" ]]; then
    echo -e "  ${GREEN}[${i}/${TOTAL}] ✔  nginx=${nginx_code}  gateway=${gw_code}  — match${NC}"
    ((PASS++))
  else
    echo -e "  ${RED}[${i}/${TOTAL}] ✘  nginx=${nginx_code}  gateway=${gw_code}  — MISMATCH${NC}"
    ((FAIL++))
  fi
  sleep 0.3
done

echo ""
echo -e "  ${BOLD}Result: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  out of ${TOTAL}"

if [[ $FAIL -gt 0 ]]; then
  err "Validation failed — do NOT proceed to cutover"
  warn "Check Gateway status: kubectl get gateway gpen-gateway -o yaml"
  warn "Check HTTPRoute status: kubectl get httproute -o yaml"
  if confirm "  Show rollback options?"; then
    echo -e "\n  ${BOLD}Rollback: restore original Ingress (Gateway API resources unaffected)${NC}"
    echo -e "  ${DIM}\$ kubectl apply -f $BACKUP_FILE${NC}"
    echo -e "  ${DIM}\$ kubectl delete httproute --all${NC}"
  fi
  pause
else
  ok "All ${PASS}/${TOTAL} requests match — Gateway API path is healthy"
  ok "Safe to proceed to cutover"
fi

pause

# ════════════════════════════════════════════════════════════════
phase 5 "CUTOVER — Remove Ingress, Gateway API takes full control"
# ════════════════════════════════════════════════════════════════

echo -e "\n  ${BOLD}${YELLOW}POINT OF NO RETURN (but rollback is still fast):${NC}"
echo -e "  Rollback: kubectl apply -f $BACKUP_FILE"
echo -e "  Rollback time: ~5 seconds\n"

if confirm "  Proceed with Ingress deletion?"; then
  step "Deleting legacy Ingress resource"
  run "kubectl delete ingress gpen-ingress"
  ok "Ingress deleted — 100% traffic now through Gateway API"

  sleep 2

  step "Post-cutover validation"
  for path in "/" "/api"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: gpen.local" "http://localhost:$EG_PORT$path" 2>/dev/null)
    body=$(curl -s -H "Host: gpen.local" "http://localhost:$EG_PORT$path" 2>/dev/null)
    [[ "$code" == "200" ]] \
      && ok "GET $path → $code  [$body]" \
      || err "GET $path → $code (unexpected)"
  done
else
  warn "Cutover skipped — Ingress still running"
fi

pause

# ════════════════════════════════════════════════════════════════
phase 6 "BONUS — Canary traffic split (native weight:)"
# ════════════════════════════════════════════════════════════════

step "Update HTTPRoute: 90% api-v1 / 10% api-v2 — no annotations"
run "cat $DEMO_DIR/gateway/02-canary.yaml"
run "kubectl apply -f $DEMO_DIR/gateway/02-canary.yaml"
sleep 2

step "Hit /api 20 times — watch traffic distribution"
echo ""
V1=0; V2=0
for i in $(seq 1 20); do
  body=$(curl -s -H "Host: gpen.local" "http://localhost:$EG_PORT/api" 2>/dev/null)
  if echo "$body" | grep -q "v2"; then
    echo -e "  ${GREEN}[${i}] ← CANARY  $body${NC}"
    ((V2++))
  else
    echo -e "  ${BLUE}[${i}]  $body${NC}"
    ((V1++))
  fi
  sleep 0.2
done

echo ""
echo -e "  ${BOLD}Distribution: v1=${V1}/20  v2=${V2}/20  (target ~18/2)${NC}"
echo -e "  ${BLUE}ℹ weight: 90/10 — impossible with nginx Ingress annotations${NC}"
pause

stop_pf

# ════════════════════════════════════════════════════════════════
banner "Migration Complete 🎉"
# ════════════════════════════════════════════════════════════════
echo -e "  ${GREEN}✔ Phase 0 — Pre-flight audit + ingress backup${NC}"
echo -e "  ${GREEN}✔ Phase 1 — GatewayClass + Gateway (platform infra)${NC}"
echo -e "  ${GREEN}✔ Phase 2 — ingress2gateway converted Ingress → HTTPRoute${NC}"
echo -e "  ${GREEN}✔ Phase 3 — Parallel run (both paths live, zero downtime)${NC}"
echo -e "  ${GREEN}✔ Phase 4 — Automated validation (nginx vs Envoy comparison)${NC}"
echo -e "  ${GREEN}✔ Phase 5 — Cutover: Ingress deleted, Gateway API owns traffic${NC}"
echo -e "  ${GREEN}✔ Phase 6 — Canary 90/10 split with native weight:${NC}"
echo ""
echo -e "  Rollback file kept at: ${DIM}$BACKUP_FILE${NC}"
echo -e "  Bonus features: ${DIM}./scripts/03-enhance.sh${NC}  (CORS · header routing · rewrite · cross-namespace)"
echo -e "  Cleanup: ${DIM}./scripts/05-cleanup.sh${NC}"
echo ""
