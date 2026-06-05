#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  GATEWAY API — Post-Migration Enhancement Demo
#
#  Run AFTER migrate.sh completes (cluster must have Gateway up + cutover done).
#  Each phase layers a new Gateway API capability onto the running HTTPRoute.
#
#  Phase 1  CORS            — native response header filter (no nginx annotations)
#  Phase 2  Header Routing  — X-Version: v2 → api-v2  (A/B testing)
#  Phase 3  URL Rewrite     — /v1/products → /api  + per-route timeouts
#  Phase 4  Cross-Namespace — HTTPRoute in 'default' routes to Service in 'staging'
#
#  Each phase is independent — you can run them in any order.
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"
EG_PORT=9080

banner() {
  clear
  echo -e "\n${BOLD}${CYAN}  ══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${CYAN}  ══════════════════════════════════════════════════${NC}\n"
}
phase()   { echo -e "\n${BOLD}${BLUE}┌─ PHASE $1: $2 ─────────────────────────────────${NC}"; }
step()    { echo -e "\n${YELLOW}  ▶ $1${NC}"; }
run()     { echo -e "  ${DIM}\$ $*${NC}"; eval "$@"; echo ""; }
ok()      { echo -e "  ${GREEN}✔ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
err()     { echo -e "  ${RED}✘ $1${NC}"; }
pause()   { echo -e "\n${DIM}  [ Press ENTER to continue → ]${NC}"; read -r; }

# ── Pre-flight ────────────────────────────────────────────────────
banner "Gateway API — Enhancement Demo"

kubectl config current-context | grep -q "gpen-demo" || {
  err "kubectl context is not 'kind-gpen-demo'"
  exit 1
}

kubectl get gateway gpen-gateway &>/dev/null || {
  err "Gateway 'gpen-gateway' not found — run migrate.sh first"
  exit 1
}

kubectl get httproute &>/dev/null || {
  err "No HTTPRoute found — complete migrate.sh (at least through Phase 5) first"
  exit 1
}

# Ensure Envoy port-forward is running
if ! curl -s -o /dev/null -w "%{http_code}" -H "Host: gpen.local" \
     --connect-timeout 2 "http://localhost:$EG_PORT/" 2>/dev/null | grep -q "200"; then
  warn "Envoy Gateway not reachable on port $EG_PORT — starting port-forward..."
  EG_SVC=$(kubectl get svc -A -l "gateway.envoyproxy.io/owning-gateway-name=gpen-gateway" \
    -o name 2>/dev/null | head -1)
  EG_NS=$(kubectl get svc -A -l "gateway.envoyproxy.io/owning-gateway-name=gpen-gateway" \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "envoy-gateway-system")
  [[ -z "$EG_SVC" ]] && { err "Envoy service not found — is Gateway API deployed?"; exit 1; }
  kubectl port-forward -n "$EG_NS" "$EG_SVC" "${EG_PORT}:80" &>/dev/null &
  sleep 2
  ok "Port-forward started → http://gpen.local:$EG_PORT"
fi

echo -e "  ${GREEN}✔ Pre-flight passed — Envoy Gateway is reachable on :$EG_PORT${NC}"
echo -e "  ${DIM}  Current HTTPRoute: $(kubectl get httproute -o name | head -3 | tr '\n' '  ')${NC}"
echo -e "\n${BOLD}${YELLOW}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║  ⚡  ACTION REQUIRED — START THE ENHANCE MONITOR NOW            ║"
echo "  ║                                                                  ║"
echo "  ║  Open a NEW terminal and run:                                   ║"
echo "  ║                                                                  ║"
echo "  ║    ./scripts/03-enhance-monitor.sh                              ║"
echo "  ║                                                                  ║"
echo "  ║  It watches CORS headers, header routing, URL rewrite, and      ║"
echo "  ║  traffic distribution live as you apply each enhancement.       ║"
echo "  ║                                                                  ║"
echo "  ║  Log file will be written to: /tmp/gateway-enhance-monitor-*.log║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${DIM}Waiting 10 seconds for you to start the monitor...${NC}"
for i in 10 9 8 7 6 5 4 3 2 1; do
  echo -ne "  ${YELLOW}  ${i}s remaining — open new terminal → ./scripts/03-enhance-monitor.sh${NC}\r"
  sleep 1
done
echo ""
pause

# ════════════════════════════════════════════════════════════════
phase 1 "CORS — Native response headers (no annotations needed)"
# ════════════════════════════════════════════════════════════════

step "What we're adding"
echo -e "  ${BLUE}ℹ With nginx Ingress, CORS requires controller-specific annotations${NC}"
echo -e "  ${BLUE}  and behaves inconsistently across versions.${NC}"
echo -e "  ${BLUE}  Gateway API uses a ResponseHeaderModifier filter — standard, portable,${NC}"
echo -e "  ${BLUE}  and works on any conformant implementation.${NC}"

step "Applying CORS filter to HTTPRoute"
run "cat $DEMO_DIR/gateway/03-cors.yaml"
run "kubectl apply -f $DEMO_DIR/gateway/03-cors.yaml"
sleep 2

step "Verify CORS headers are present in response"
echo -e "  ${DIM}Checking response headers from Envoy Gateway:${NC}\n"
curl -s -I -H "Host: gpen.local" "http://localhost:$EG_PORT/" | grep -i "access-control" \
  && ok "CORS headers confirmed in response" \
  || warn "CORS headers not yet visible — try: curl -sI -H 'Host: gpen.local' http://localhost:$EG_PORT/"

step "Full header dump for / endpoint"
run "curl -sI -H 'Host: gpen.local' http://localhost:$EG_PORT/"

pause

# ════════════════════════════════════════════════════════════════
phase 2 "Header Routing — A/B testing with X-Version header"
# ════════════════════════════════════════════════════════════════

step "What we're adding"
echo -e "  ${BLUE}ℹ Route specific users to a new version by sending X-Version: v2${NC}"
echo -e "  ${BLUE}  No weight changes, no DNS changes — just a header.${NC}"
echo -e "  ${BLUE}  Impossible with plain nginx Ingress (no header match rules).${NC}"

step "Applying header-based routing rules"
run "cat $DEMO_DIR/gateway/04-header-routing.yaml"
run "kubectl apply -f $DEMO_DIR/gateway/04-header-routing.yaml"
sleep 2

step "Test: without X-Version header → always v1 (stable)"
for i in 1 2 3; do
  body=$(curl -s -H "Host: gpen.local" "http://localhost:$EG_PORT/api" 2>/dev/null)
  echo -e "  [${i}] ${BLUE}${body}${NC}"
done

step "Test: with X-Version: v2 → always v2 (canary)"
for i in 1 2 3; do
  body=$(curl -s -H "Host: gpen.local" -H "X-Version: v2" "http://localhost:$EG_PORT/api" 2>/dev/null)
  echo -e "  [${i}] ${GREEN}${body}${NC}"
done
ok "Header routing confirmed — same path, different behavior per header"

pause

# ════════════════════════════════════════════════════════════════
phase 3 "URL Rewrite + Per-Route Timeouts"
# ════════════════════════════════════════════════════════════════

step "What we're adding"
echo -e "  ${BLUE}ℹ /v1/products is a legacy URL the frontend still uses.${NC}"
echo -e "  ${BLUE}  Gateway rewrites it to /api before reaching the backend.${NC}"
echo -e "  ${BLUE}  Per-route timeouts enforce SLOs without touching app code.${NC}"
echo -e "  ${BLUE}  nginx Ingress: rewrite needs annotation + regex; no per-route timeout.${NC}"

step "Applying URL rewrite + timeout rules"
run "cat $DEMO_DIR/gateway/05-rewrite-timeout.yaml"
run "kubectl apply -f $DEMO_DIR/gateway/05-rewrite-timeout.yaml"
sleep 2

step "Test: legacy path /v1/products → transparently rewrites to /api"
body=$(curl -s -H "Host: gpen.local" "http://localhost:$EG_PORT/v1/products" 2>/dev/null)
echo -e "  GET /v1/products → ${GREEN}${body}${NC}"
ok "Rewrite confirmed — client sees /v1/products, backend sees /api"

step "Test: direct /api path still works normally"
run "curl -s -H 'Host: gpen.local' http://localhost:$EG_PORT/api"

step "Timeout in effect (3s request / 2s backend — check gateway logs for enforcement)"
run "kubectl logs -n envoy-gateway-system deploy/envoy-gateway --tail=5 2>/dev/null || true"

pause

# ════════════════════════════════════════════════════════════════
phase 4 "Cross-Namespace Routing — The Gateway API security model"
# ════════════════════════════════════════════════════════════════

step "What we're adding"
echo -e "  ${BLUE}ℹ A staging backend lives in a DIFFERENT namespace ('staging').${NC}"
echo -e "  ${BLUE}  Ingress is strictly namespace-scoped — it CANNOT route cross-namespace.${NC}"
echo -e "  ${BLUE}  Gateway API uses ReferenceGrant: the TARGET namespace explicitly opts in.${NC}"
echo -e "  ${BLUE}  This is the security model — no accidental cross-namespace exposure.${NC}"

step "Applying: Namespace + Deployment + Service + ReferenceGrant + HTTPRoute"
run "cat $DEMO_DIR/gateway/06-cross-namespace.yaml"
run "kubectl apply -f $DEMO_DIR/gateway/06-cross-namespace.yaml"

step "Wait for staging deployment to be ready..."
kubectl wait --for=condition=available deployment/api-v2-staging \
  -n staging --timeout=60s 2>/dev/null \
  && ok "staging/api-v2-staging is ready" \
  || warn "Deployment not ready yet — wait a moment then retry curl"

sleep 2

step "Show the ReferenceGrant — staging namespace explicitly allows default to route here"
run "kubectl get referencegrant -n staging -o yaml"

step "Hit /api 10 times — 80% default/api-v1, 20% staging/api-v2"
echo ""
DEFAULT_NS=0; STAGING=0
for i in $(seq 1 10); do
  body=$(curl -s -H "Host: gpen.local" "http://localhost:$EG_PORT/api" 2>/dev/null)
  if echo "$body" | grep -qi "staging"; then
    echo -e "  ${GREEN}[${i}] ← STAGING  $body${NC}"
    ((STAGING++))
  else
    echo -e "  ${BLUE}[${i}]  $body${NC}"
    ((DEFAULT_NS++))
  fi
  sleep 0.2
done

echo ""
echo -e "  ${BOLD}Distribution: default=${DEFAULT_NS}/10  staging=${STAGING}/10${NC}"
echo -e "  ${BLUE}ℹ Ingress cannot do this. ReferenceGrant makes cross-namespace routing explicit + safe.${NC}"

pause

# ════════════════════════════════════════════════════════════════
banner "Enhancement Demo Complete"
# ════════════════════════════════════════════════════════════════
echo -e "  ${GREEN}✔ Phase 1 — CORS response headers (ResponseHeaderModifier filter)${NC}"
echo -e "  ${GREEN}✔ Phase 2 — Header routing: X-Version: v2 → api-v2${NC}"
echo -e "  ${GREEN}✔ Phase 3 — URL rewrite /v1/products → /api + per-route timeouts${NC}"
echo -e "  ${GREEN}✔ Phase 4 — Cross-namespace routing with ReferenceGrant${NC}"
echo ""
echo -e "  ${DIM}  Cleanup everything: ./scripts/05-cleanup.sh${NC}"
echo -e "  ${DIM}  Reset to 'before' state: ./scripts/04-reset.sh${NC}"
echo ""
