#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  GATEWAY API — Enhancement Live Monitor
#
#  Run in a SEPARATE terminal during enhance.sh phases.
#  Watches Envoy Gateway only (nginx is gone after cutover).
#
#  Shows per-phase relevant signals:
#    /           — CORS: Access-Control-Allow-Origin header present?
#    /api        — distribution: v1 vs v2 vs staging
#    /api + hdr  — header routing: X-Version:v2 always → v2?
#    /v1/products — rewrite: same response as /api?
#
#  Usage:  ./scripts/03-enhance-monitor.sh
#          ./scripts/03-enhance-monitor.sh --interval 0.5
# ══════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'
MAGENTA='\033[0;35m'; NC='\033[0m'

EG_PORT=9080
INTERVAL=1
[[ "${1:-}" == "--interval" && -n "${2:-}" ]] && INTERVAL=$2

LOG_FILE="/tmp/gateway-enhance-monitor-$(date +%Y%m%d-%H%M%S).log"

# ── Counters ─────────────────────────────────────────────────────
declare -A v1_count v2_count staging_count err_count
for k in api api_hdr products root; do
  v1_count[$k]=0; v2_count[$k]=0; staging_count[$k]=0; err_count[$k]=0
done
cors_present=0; cors_missing=0
rewrite_match=0; rewrite_mismatch=0
header_route_ok=0; header_route_fail=0
TOTAL=0
START_TIME=$(date +%s)

# ── Helpers ──────────────────────────────────────────────────────
ts()  { date '+%H:%M:%S'; }
log() { echo -e "$*" | tee -a "$LOG_FILE"; }

# curl with timing: sets RESP_TIME_MS and RESP_BODY, returns http_code
curl_timed() {
  local url=$1 host=$2
  local extra_opts=("${@:3}")
  local out
  out=$(curl -s -o /tmp/gw_enh_body_$$ -w "%{http_code} %{time_total}" \
    -H "Host: $host" --connect-timeout 2 "${extra_opts[@]}" "$url" 2>/dev/null || echo "ERR 0")
  local code time_s
  read -r code time_s <<< "$out"
  RESP_TIME_MS=$(awk "BEGIN{printf \"%d\", ${time_s:-0} * 1000}")
  RESP_BODY=$(cat /tmp/gw_enh_body_$$ 2>/dev/null | head -c 60 || echo "")
  rm -f /tmp/gw_enh_body_$$
  echo "$code"
}

clear
log "${BOLD}${CYAN}"
log "  ╔══════════════════════════════════════════════════════════════════╗"
log "  ║       Enhancement Monitor — Gateway API Demo                    ║"
log "  ║       Envoy Gateway :$EG_PORT only (post-cutover)                  ║"
log "  ║                                                                  ║"
log "  ║  Tracks per phase:                                              ║"
log "  ║    Phase 1 → CORS header on /                                   ║"
log "  ║    Phase 2 → Header routing  /api + X-Version:v2               ║"
log "  ║    Phase 3 → URL rewrite  /v1/products → /api                  ║"
log "  ║    All     → Traffic distribution  v1 / v2 / staging           ║"
log "  ║                                                                  ║"
log "  ║  Ctrl+C to stop and see full summary                            ║"
log "  ╚══════════════════════════════════════════════════════════════════╝"
log "${NC}"
log "  ${DIM}Log file: $LOG_FILE${NC}"
log "  ${DIM}Polling interval: ${INTERVAL}s  |  Started: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
log ""

# ── Stats printer ─────────────────────────────────────────────────
print_stats() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))
  log "\n${BOLD}  ── Stats snapshot  [$(ts)]  (${mins}m${secs}s · ${TOTAL} cycles) ──────────────────${NC}"

  # Traffic distribution
  local api_total=$(( v1_count[api] + v2_count[api] + staging_count[api] + err_count[api] ))
  local v1_pct=0 v2_pct=0 stg_pct=0
  if [[ $api_total -gt 0 ]]; then
    v1_pct=$(( v1_count[api] * 100 / api_total ))
    v2_pct=$(( v2_count[api] * 100 / api_total ))
    stg_pct=$(( staging_count[api] * 100 / api_total ))
  fi
  log "  ${BOLD}Traffic distribution  GET /api (no header) — ${api_total} requests:${NC}"
  log "    ${BLUE}v1=${v1_count[api]}(${v1_pct}%)${NC}  ${GREEN}v2=${v2_count[api]}(${v2_pct}%)${NC}  ${MAGENTA}staging=${staging_count[api]}(${stg_pct}%)${NC}  ${RED}err=${err_count[api]}${NC}"

  # Header routing
  local hdr_total=$(( header_route_ok + header_route_fail + err_count[api_hdr] ))
  log "  ${BOLD}Header routing  GET /api + X-Version:v2 — ${hdr_total} requests:${NC}"
  log "    ${GREEN}correctly→v2=${header_route_ok}${NC}  ${RED}leaked-to-v1=${header_route_fail}${NC}  ${RED}err=${err_count[api_hdr]}${NC}"

  # URL rewrite
  local rw_total=$(( rewrite_match + rewrite_mismatch + err_count[products] ))
  log "  ${BOLD}URL rewrite  GET /v1/products → /api — ${rw_total} requests:${NC}"
  log "    ${GREEN}body-match=${rewrite_match}${NC}  ${RED}mismatch=${rewrite_mismatch}${NC}  ${YELLOW}no-route=${err_count[products]}${NC}"

  # CORS
  local cors_total=$(( cors_present + cors_missing ))
  local cors_pct=0
  [[ $cors_total -gt 0 ]] && cors_pct=$(( cors_present * 100 / cors_total ))
  log "  ${BOLD}CORS  Access-Control-Allow-Origin on / — ${cors_total} checks:${NC}"
  log "    ${GREEN}header-present=${cors_present}(${cors_pct}%)${NC}  ${YELLOW}missing=${cors_missing}${NC}"
  echo "" | tee -a "$LOG_FILE"
}

trap_summary() {
  echo "" | tee -a "$LOG_FILE"
  log "${BOLD}${CYAN}  ══ Enhancement Monitor — Final Summary ═══════════════════════════${NC}"
  log "  Ended:        $(date '+%Y-%m-%d %H:%M:%S')"
  log "  Total cycles: $TOTAL"
  print_stats

  local issues=0
  [[ $header_route_fail -gt 0 ]] && {
    log "  ${RED}✘ Header routing leaked to v1 ${header_route_fail}× — check HTTPRoute rules order${NC}"
    issues=1
  }
  [[ $rewrite_mismatch -gt 0 ]] && {
    log "  ${RED}✘ Rewrite body differs from /api ${rewrite_mismatch}× — check URLRewrite filter${NC}"
    issues=1
  }
  [[ $cors_missing -gt 5 && $cors_present -eq 0 ]] && {
    log "  ${YELLOW}⚠ CORS headers never seen — run: kubectl apply -f gateway/03-cors.yaml${NC}"
    issues=1
  }
  [[ $issues -eq 0 ]] && \
    log "  ${GREEN}${BOLD}✔ All enhancement signals healthy${NC}"
  log "\n  ${DIM}Full log saved to: $LOG_FILE${NC}\n"
  exit 0
}
trap trap_summary SIGINT SIGTERM

# ── Main loop ─────────────────────────────────────────────────────
check_count=0
HEADER_EVERY=8

while true; do
  if (( check_count % HEADER_EVERY == 0 )); then
    log "\n${DIM}  [$(ts)]  Envoy :$EG_PORT — cycle #${TOTAL} — polling every ${INTERVAL}s${NC}"
    printf "  ${DIM}%-8s  %-30s  %-12s  %-8s  %s${NC}\n" \
      "TIME" "CHECK" "RESULT" "ms" "DETAIL" | tee -a "$LOG_FILE"
    printf "  ${DIM}%-8s  %-30s  %-12s  %-8s  %s${NC}\n" \
      "────────" "──────────────────────────────" "────────────" "────────" "──────────────────────────────" | tee -a "$LOG_FILE"
  fi

  now="$(ts)"

  # 1. GET /api — track v1/v2/staging distribution
  api_code=$(curl_timed "http://localhost:$EG_PORT/api" "gpen.local")
  api_body="$RESP_BODY"; api_ms="$RESP_TIME_MS"
  if echo "$api_body" | grep -qi "staging"; then
    api_class="${MAGENTA}staging${NC}"; staging_count[api]=$(( staging_count[api] + 1 ))
  elif echo "$api_body" | grep -qi "v2"; then
    api_class="${GREEN}v2${NC}";       v2_count[api]=$(( v2_count[api] + 1 ))
  elif [[ "$api_code" != "200" || -z "$api_body" ]]; then
    api_class="${RED}ERR${NC}";        err_count[api]=$(( err_count[api] + 1 ))
  else
    api_class="${BLUE}v1${NC}";        v1_count[api]=$(( v1_count[api] + 1 ))
  fi
  printf "  %-8s  %-30s  " "$now" "GET /api" | tee -a "$LOG_FILE"
  echo -e "${api_class}  (${api_code})      ${DIM}${api_ms}ms${NC}  ${DIM}${api_body:0:45}${NC}" | tee -a "$LOG_FILE"

  # 2. GET /api + X-Version:v2 — must ALWAYS go to v2
  hdr_code=$(curl_timed "http://localhost:$EG_PORT/api" "gpen.local" -H "X-Version: v2")
  hdr_body="$RESP_BODY"; hdr_ms="$RESP_TIME_MS"
  if [[ "$hdr_code" == "ERR" || -z "$hdr_body" ]]; then
    hdr_signal="${RED}ERR${NC}"; err_count[api_hdr]=$(( err_count[api_hdr] + 1 ))
  elif echo "$hdr_body" | grep -qi "v2"; then
    hdr_signal="${GREEN}✔ → v2${NC}"; header_route_ok=$(( header_route_ok + 1 ))
  else
    hdr_signal="${RED}✘ leaked→v1${NC}"; header_route_fail=$(( header_route_fail + 1 ))
  fi
  printf "  %-8s  %-30s  " "$now" "GET /api  X-Version:v2" | tee -a "$LOG_FILE"
  echo -e "${hdr_signal}   ${DIM}${hdr_ms}ms${NC}  ${DIM}${hdr_body:0:45}${NC}" | tee -a "$LOG_FILE"

  # 3. GET /v1/products — should rewrite to /api, body must match api_body
  rw_code=$(curl_timed "http://localhost:$EG_PORT/v1/products" "gpen.local")
  rw_body="$RESP_BODY"; rw_ms="$RESP_TIME_MS"
  if [[ "$rw_code" == "ERR" || -z "$rw_body" ]]; then
    rw_signal="${YELLOW}no route yet${NC}"; err_count[products]=$(( err_count[products] + 1 ))
  elif [[ "$rw_body" == "$api_body" ]]; then
    rw_signal="${GREEN}✔ body match${NC}"; rewrite_match=$(( rewrite_match + 1 ))
  else
    rw_signal="${YELLOW}≠ body diff${NC}"; rewrite_mismatch=$(( rewrite_mismatch + 1 ))
  fi
  printf "  %-8s  %-30s  " "$now" "GET /v1/products" | tee -a "$LOG_FILE"
  echo -e "${rw_signal}  ${DIM}${rw_ms}ms${NC}  ${DIM}${rw_body:0:45}${NC}" | tee -a "$LOG_FILE"

  # 4. HEAD / — check for CORS header
  cors_raw=$(curl -sI -H "Host: gpen.local" --connect-timeout 2 \
    "http://localhost:$EG_PORT/" 2>/dev/null \
    | grep -i "access-control-allow-origin" | tr -d '\r' | head -c 80 || echo "")
  if [[ -n "$cors_raw" ]]; then
    cors_signal="${GREEN}✔ CORS present${NC}"; cors_present=$(( cors_present + 1 ))
  else
    cors_signal="${DIM}no CORS yet${NC}";     cors_missing=$(( cors_missing + 1 ))
  fi
  printf "  %-8s  %-30s  " "$now" "HEAD /  (CORS)" | tee -a "$LOG_FILE"
  echo -e "${cors_signal}          ${DIM}${cors_raw:0:55}${NC}" | tee -a "$LOG_FILE"

  TOTAL=$(( TOTAL + 1 ))
  check_count=$(( check_count + 1 ))
  [[ $(( check_count % 20 )) -eq 0 ]] && { print_stats; check_count=0; }

  sleep "$INTERVAL"
done
