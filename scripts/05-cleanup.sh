#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  FULL CLEANUP — deletes kind cluster + everything inside it
#  Run when you're completely done with the demo.
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(dirname "$SCRIPT_DIR")"

ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
chk()  { echo -e "  ${CYAN}▶ $*${NC}"; }

echo -e "\n${BOLD}${CYAN}  ── Full Cleanup ──────────────────────────────────────${NC}\n"

# ── Stop port-forwards ───────────────────────────────────────────
chk "Stopping port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
ok "port-forwards stopped"

# ── Delete kind clusters ─────────────────────────────────────────
chk "Checking for kind clusters..."
ALL_CLUSTERS=$(kind get clusters 2>/dev/null || echo "")

# Delete gpen-demo (current name)
if echo "$ALL_CLUSTERS" | grep -q "^gpen-demo$"; then
  chk "Deleting kind cluster 'gpen-demo'..."
  kind delete cluster --name gpen-demo
  ok "cluster 'gpen-demo' deleted"
else
  warn "cluster 'gpen-demo' not found — skipping"
fi

# Also clean up old 'gateway-demo' cluster if it still exists
if echo "$ALL_CLUSTERS" | grep -q "^gateway-demo$"; then
  chk "Found old cluster 'gateway-demo' — deleting..."
  kind delete cluster --name gateway-demo
  ok "cluster 'gateway-demo' deleted"
fi

# ── Remove generated files ───────────────────────────────────────
chk "Removing generated files..."
rm -f "$DEMO_DIR/ingress-backup.yaml"
rm -f "$DEMO_DIR/gateway/ingress2gateway-converted.yaml"
ok "generated files removed"

# ══════════════════════════════════════════════════════════════════
#  POST-CLEANUP VERIFICATION
# ══════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}  ── Post-Cleanup Verification ─────────────────────────${NC}\n"

# ── Kind clusters ────────────────────────────────────────────────
echo -e "${BOLD}  ┌─ KIND CLUSTERS ────────────────────────────────────────────┐${NC}"
REMAINING=$(kind get clusters 2>/dev/null || echo "")
if [[ -z "$REMAINING" ]]; then
  ok "No kind clusters running"
else
  warn "Clusters still present:"
  echo "$REMAINING" | while read -r c; do
    echo -e "    ${YELLOW}• $c${NC}"
  done
  echo -e "  ${DIM}  Manual delete: kind delete cluster --name <name>${NC}"
fi
echo -e "${BOLD}  └───────────────────────────────────────────────────────────┘${NC}\n"

# ── Docker containers ────────────────────────────────────────────
echo -e "${BOLD}  ┌─ DOCKER (kind containers) ─────────────────────────────────┐${NC}"
KIND_CONTAINERS=$(docker ps --filter "label=io.x-k8s.kind.cluster" --format "{{.Names}}  [{{.Status}}]" 2>/dev/null || echo "")
if [[ -z "$KIND_CONTAINERS" ]]; then
  ok "No kind Docker containers running"
else
  warn "Kind containers still running:"
  echo "$KIND_CONTAINERS" | while read -r c; do
    echo -e "    ${YELLOW}• $c${NC}"
  done
  echo -e "  ${DIM}  Manual stop: docker rm -f <container>${NC}"
fi
echo -e "${BOLD}  └───────────────────────────────────────────────────────────┘${NC}\n"

# ── kubectl context ──────────────────────────────────────────────
echo -e "${BOLD}  ┌─ KUBECTL CONTEXT ──────────────────────────────────────────┐${NC}"
CTX=$(kubectl config current-context 2>/dev/null || echo "none")
if echo "$CTX" | grep -q "gpen-demo\|gateway-demo"; then
  warn "kubectl still pointing to deleted cluster: $CTX"
  echo -e "  ${DIM}  Switch context: kubectl config use-context <another-context>${NC}"
else
  ok "kubectl context: $CTX"
fi
echo -e "${BOLD}  └───────────────────────────────────────────────────────────┘${NC}\n"

# ── /etc/hosts ───────────────────────────────────────────────────
echo -e "${BOLD}  ┌─ /ETC/HOSTS ───────────────────────────────────────────────┐${NC}"
GPEN_ENTRY=$(grep "gpen\.local" /etc/hosts 2>/dev/null || echo "")
DEMO_ENTRY=$(grep "demo\.local" /etc/hosts 2>/dev/null || echo "")
if [[ -n "$GPEN_ENTRY" ]]; then
  warn "gpen.local still in /etc/hosts (needed for next setup.sh run — keep it)"
  echo -e "  ${DIM}    $GPEN_ENTRY${NC}"
else
  ok "gpen.local not in /etc/hosts (setup.sh will add it)"
fi
if [[ -n "$DEMO_ENTRY" ]]; then
  warn "Old demo.local entry still present (unused — safe to remove):"
  echo -e "  ${DIM}    $DEMO_ENTRY${NC}"
  echo -e "  ${DIM}  Remove: sudo sed -i '' '/demo\\.local/d' /etc/hosts${NC}"
fi
echo -e "${BOLD}  └───────────────────────────────────────────────────────────┘${NC}\n"

# ── Generated files ──────────────────────────────────────────────
echo -e "${BOLD}  ┌─ GENERATED FILES ──────────────────────────────────────────┐${NC}"
[[ -f "$DEMO_DIR/ingress-backup.yaml" ]]                     && warn "ingress-backup.yaml still present" \
                                                             || ok "ingress-backup.yaml — gone"
[[ -f "$DEMO_DIR/gateway/ingress2gateway-converted.yaml" ]]  && warn "ingress2gateway-converted.yaml still present" \
                                                             || ok "ingress2gateway-converted.yaml — gone"
echo -e "${BOLD}  └───────────────────────────────────────────────────────────┘${NC}\n"

# ── Summary ──────────────────────────────────────────────────────
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║  Cleanup done — environment is clear                            ║"
echo "  ║                                                                  ║"
echo "  ║  Next: ./scripts/01-setup.sh  (takes ~5–8 min)                  ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
