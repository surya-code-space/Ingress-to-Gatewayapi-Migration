#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  GATEWAY API DEMO — Live Migration Monitor
#
#  Run in a SEPARATE terminal during Phase 3 (parallel run).
#  Smart phase detection — understands cutover is EXPECTED.
#
#  Phase states detected automatically:
#    WAITING     — Envoy not reachable yet (port-forward not started)
#    PARALLEL    — nginx=200 + Envoy=200  ← Phase 3/4 (comparing)
#    CUTOVER     — nginx=404 + Envoy=200  ← Phase 5 (Ingress deleted, EXPECTED)
#    GW_ISSUE    — nginx=200 + Envoy=404  ← HTTPRoute problem (needs fix)
#    ENDED       — port-forward stopped   ← demo complete
#
#  Usage:  ./scripts/02-migrate-monitor.sh
#          ./scripts/02-migrate-monitor.sh --interval 0.5
# ══════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
MAGENTA='\033[0;35m'

NGINX_PORT=8080
EG_PORT=9080
INTERVAL=1
[[ "${1:-}" == "--interval" && -n "${2:-}" ]] && INTERVAL=$2

LOG_FILE="/tmp/gateway-migrate-monitor-$(date +%Y%m%d-%H%M%S).log"

PATHS=("/" "/api")
KEYS=("root" "api")

# Counters
declare -A nginx_ok nginx_fail gw_ok gw_fail mismatch cutover_ok
for k in "${KEYS[@]}"; do
  nginx_ok[$k]=0; nginx_fail[$k]=0
  gw_ok[$k]=0;    gw_fail[$k]=0
  mismatch[$k]=0; cutover_ok[$k]=0
done
TOTAL_CHECKS=0
START_TIME=$(date +%s)
CURRENT_PHASE="WAITING"
LAST_PHASE=""

# ── Helpers ──────────────────────────────────────────────────────
ts()  { date '+%H:%M:%S'; }
log() { echo -e "$*" | tee -a "$LOG_FILE"; }

# curl_timed: sets CURL_CODE, RESP_TIME_MS, RESP_BODY — no subshell, globals work
curl_timed() {
  local url=$1 host=$2
  shift 2
  local extra_opts=("$@")
  local out
  out=$(curl -s -o /tmp/gw_mon_body_$$ -w "%{http_code} %{time_total}" \
    -H "Host: $host" --connect-timeout 2 "${extra_opts[@]}" "$url" 2>/dev/null || echo "000 0")
  read -r CURL_CODE CURL_TIME_S <<< "$out"
  RESP_TIME_MS=$(awk "BEGIN{printf \"%d\", ${CURL_TIME_S:-0} * 1000}")
  RESP_BODY=$(cat /tmp/gw_mon_body_$$ 2>/dev/null | head -c 50 || echo "")
  rm -f /tmp/gw_mon_body_$$
}

# ── Phase detector ───────────────────────────────────────────────
detect_phase() {
  local nc=$1 gc=$2
  if   [[ "$gc" == "000" || "$gc" == "ERR" ]]; then echo "ENDED"
  elif [[ "$nc" == "200" && "$gc" == "200" ]]; then echo "PARALLEL"
  elif [[ "$nc" != "200" && "$gc" == "200" ]]; then echo "CUTOVER"
  elif [[ "$nc" == "200" && "$gc" != "200" ]]; then echo "GW_ISSUE"
  else                                               echo "WAITING"
  fi
}

# ── Phase transition banner ──────────────────────────────────────
phase_banner() {
  local phase=$1
  case "$phase" in
    PARALLEL)
      log ""
      log "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
      log "${BOLD}${CYAN}  ║  📊 PHASE 3/4 — PARALLEL RUN                                    ║${NC}"
      log "${BOLD}${CYAN}  ║  What:   Both nginx AND Envoy Gateway serving live traffic       ║${NC}"
      log "${BOLD}${CYAN}  ║  Check:  nginx:8080 response == Envoy:9080 response              ║${NC}"
      log "${BOLD}${CYAN}  ║  Expect: ✔ match on every row (both return 200)                 ║${NC}"
      log "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
      log ""
      ;;
    CUTOVER)
      log ""
      log "${BOLD}${GREEN}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
      log "${BOLD}${GREEN}  ║  ✂  PHASE 5 — CUTOVER DETECTED                                  ║${NC}"
      log "${BOLD}${GREEN}  ║  What:   Ingress was deleted — nginx now returns 404             ║${NC}"
      log "${BOLD}${GREEN}  ║  Check:  Envoy Gateway still serving all traffic                 ║${NC}"
      log "${BOLD}${GREEN}  ║  Expect: nginx=404 (EXPECTED ✔)  Envoy=200 (EXPECTED ✔)        ║${NC}"
      log "${BOLD}${GREEN}  ║  This is NOT a mismatch — this is successful cutover!            ║${NC}"
      log "${BOLD}${GREEN}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
      log ""
      ;;
    GW_ISSUE)
      log ""
      log "${BOLD}${RED}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
      log "${BOLD}${RED}  ║  ✘ GATEWAY ISSUE DETECTED                                        ║${NC}"
      log "${BOLD}${RED}  ║  What:   nginx=200 but Envoy=404                                 ║${NC}"
      log "${BOLD}${RED}  ║  Cause:  HTTPRoute not linked to gpen-gateway (parentRef wrong)  ║${NC}"
      log "${BOLD}${RED}  ║  Fix:    kubectl get httproute -o yaml | grep parentRefs -A3     ║${NC}"
      log "${BOLD}${RED}  ║  Do NOT proceed to cutover until Envoy returns 200               ║${NC}"
      log "${BOLD}${RED}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
      log ""
      ;;
    ENDED)
      log ""
      log "${BOLD}${DIM}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
      log "${BOLD}${DIM}  ║  ■  PORT-FORWARD STOPPED — demo script completed                 ║${NC}"
      log "${BOLD}${DIM}  ║  Envoy Gateway port-forward was closed by migrate.sh             ║${NC}"
      log "${BOLD}${DIM}  ║  Stopping monitor and printing final summary...                  ║${NC}"
      log "${BOLD}${DIM}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
      log ""
      ;;
    WAITING)
      log ""
      log "${BOLD}${YELLOW}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
      log "${BOLD}${YELLOW}  ║  ⏳ WAITING — Envoy Gateway not reachable yet                   ║${NC}"
      log "${BOLD}${YELLOW}  ║  Waiting for migrate.sh Phase 3 to start port-forward          ║${NC}"
      log "${BOLD}${YELLOW}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
      log ""
      ;;
  esac
}

print_stats() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))
  log "\n${BOLD}  ── Stats snapshot  [$(ts)]  (${mins}m${secs}s · ${TOTAL_CHECKS} cycles) ──────────────────${NC}"
  printf "  ${DIM}%-10s  %-8s  %-24s  %-24s  %s${NC}\n" \
    "PATH" "CHECKS" "nginx :$NGINX_PORT" "Envoy :$EG_PORT" "STATUS" | tee -a "$LOG_FILE"
  printf "  ${DIM}%-10s  %-8s  %-24s  %-24s  %s${NC}\n" \
    "──────────" "────────" "────────────────────────" "────────────────────────" "──────────" | tee -a "$LOG_FILE"
  for idx in "${!PATHS[@]}"; do
    local p="${PATHS[$idx]}" k="${KEYS[$idx]}"
    local checks=$(( nginx_ok[$k] + nginx_fail[$k] ))
    local n_pct=0 g_pct=0 c_pct=0
    [[ $checks -gt 0 ]] && n_pct=$(( nginx_ok[$k] * 100 / checks ))
    [[ $checks -gt 0 ]] && g_pct=$(( gw_ok[$k] * 100 / checks ))
    [[ $checks -gt 0 ]] && c_pct=$(( cutover_ok[$k] * 100 / checks ))
    local status_str
    if   [[ ${mismatch[$k]} -gt 0 && ${cutover_ok[$k]} -eq ${mismatch[$k]} ]]; then
      status_str="${GREEN}✔ cutover only${NC}"
    elif [[ ${mismatch[$k]} -gt 0 ]]; then
      status_str="${RED}✘ ${mismatch[$k]} real mismatch(es)${NC}"
    elif [[ ${nginx_fail[$k]} -gt 0 || ${gw_fail[$k]} -gt 0 ]]; then
      status_str="${YELLOW}⚠ errors seen${NC}"
    else
      status_str="${GREEN}✔ all matching${NC}"
    fi
    printf "  %-10s  %-8s  " "$p" "$checks" | tee -a "$LOG_FILE"
    echo -e "${GREEN}${nginx_ok[$k]} ok${NC}(${n_pct}%)/${RED}${nginx_fail[$k]} err${NC}  ${GREEN}${gw_ok[$k]} ok${NC}(${g_pct}%)/${RED}${gw_fail[$k]} err${NC}  ${CYAN}cutover=${cutover_ok[$k]}${NC}  ${status_str}" \
      | tee -a "$LOG_FILE"
  done
  echo "" | tee -a "$LOG_FILE"
}

trap_summary() {
  echo "" | tee -a "$LOG_FILE"
  log "${BOLD}${CYAN}  ══ Migration Monitor — Final Summary ══════════════════════════${NC}"
  log "  Ended:        $(date '+%Y-%m-%d %H:%M:%S')"
  log "  Total cycles: $TOTAL_CHECKS"
  print_stats

  local real_issues=0
  for k in "${KEYS[@]}"; do
    local real=$(( mismatch[$k] - cutover_ok[$k] ))
    [[ $real -gt 0 ]] && real_issues=1
  done

  if [[ $real_issues -eq 0 ]]; then
    log "  ${GREEN}${BOLD}✔ Migration successful — all mismatches were expected cutover events${NC}"
  else
    log "  ${RED}${BOLD}✘ Real mismatches detected — investigate HTTPRoute before cutover${NC}"
  fi
  log "\n  ${DIM}Full log saved to: $LOG_FILE${NC}\n"
  exit 0
}
trap trap_summary SIGINT SIGTERM

# ── Header ───────────────────────────────────────────────────────
clear
log "${BOLD}${CYAN}"
log "  ╔══════════════════════════════════════════════════════════════════╗"
log "  ║         Live Migration Monitor — Gateway API Demo               ║"
log "  ║  nginx:$NGINX_PORT (before)   vs   Envoy Gateway:$EG_PORT (after)      ║"
log "  ║                                                                  ║"
log "  ║  Phases detected automatically:                                  ║"
log "  ║    PARALLEL → nginx=200 + Envoy=200  (Phase 3/4)               ║"
log "  ║    CUTOVER  → nginx=404 + Envoy=200  (Phase 5 — EXPECTED ✔)   ║"
log "  ║    GW_ISSUE → nginx=200 + Envoy=404  (HTTPRoute problem)       ║"
log "  ║                                                                  ║"
log "  ║  Ctrl+C to stop and see full summary                            ║"
log "  ╚══════════════════════════════════════════════════════════════════╝"
log "${NC}"
log "  ${DIM}Log file: $LOG_FILE${NC}"
log "  ${DIM}Polling interval: ${INTERVAL}s  |  Started: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ── Main loop ─────────────────────────────────────────────────────
check_count=0
HEADER_EVERY=10

while true; do
  # Print column header periodically
  if (( check_count % HEADER_EVERY == 0 )); then
    log "\n${DIM}  [$(ts)]  cycle #${TOTAL_CHECKS} — polling every ${INTERVAL}s  |  phase: ${CURRENT_PHASE}${NC}"
    printf "  ${DIM}%-8s  %-6s  %-25s  %-8s  %-8s  %-7s  %-14s  %s${NC}\n" \
      "TIME" "PHASE" "ENDPOINT" "NGINX" "ENVOY" "ms" "STATUS" "BODY" | tee -a "$LOG_FILE"
    printf "  ${DIM}%-8s  %-6s  %-25s  %-8s  %-8s  %-7s  %-14s  %s${NC}\n" \
      "────────" "──────" "─────────────────────────" "────────" "────────" "───────" "──────────────" "──────────" | tee -a "$LOG_FILE"
  fi

  for idx in "${!PATHS[@]}"; do
    p="${PATHS[$idx]}"
    k="${KEYS[$idx]}"
    now="$(ts)"

    # nginx check
    curl_timed "http://localhost:$NGINX_PORT$p" "gpen.local"
    nginx_code="$CURL_CODE"; nginx_body="$RESP_BODY"

    # Envoy check
    curl_timed "http://localhost:$EG_PORT$p" "gpen.local"
    gw_code="$CURL_CODE"; gw_body="$RESP_BODY"; gw_ms="$RESP_TIME_MS"

    # Update counters
    [[ "$nginx_code" == "200" ]] && nginx_ok[$k]=$(( nginx_ok[$k] + 1 )) \
                                 || nginx_fail[$k]=$(( nginx_fail[$k] + 1 ))
    [[ "$gw_code" == "200" ]]   && gw_ok[$k]=$(( gw_ok[$k] + 1 )) \
                                 || gw_fail[$k]=$(( gw_fail[$k] + 1 ))

    # Phase detection
    CURRENT_PHASE=$(detect_phase "$nginx_code" "$gw_code")

    # Phase transition — print banner only on first row of each path
    if [[ "$CURRENT_PHASE" != "$LAST_PHASE" && "$idx" == "0" ]]; then
      phase_banner "$CURRENT_PHASE"
      LAST_PHASE="$CURRENT_PHASE"
    fi

    # Determine status label and match counting
    local_status=""
    case "$CURRENT_PHASE" in
      PARALLEL)
        local_status="${GREEN}✔ match${NC}"
        ;;
      CUTOVER)
        local_status="${GREEN}✔ cutover${NC}"
        mismatch[$k]=$(( mismatch[$k] + 1 ))
        cutover_ok[$k]=$(( cutover_ok[$k] + 1 ))
        ;;
      GW_ISSUE)
        local_status="${RED}✘ GW issue${NC}"
        mismatch[$k]=$(( mismatch[$k] + 1 ))
        ;;
      ENDED)
        local_status="${DIM}■ pf stopped${NC}"
        # Print the last row, then auto-exit with summary
        printf "  %-8s  %-6s  %-25s  " "$now" "$CURRENT_PHASE" "gpen.local${p}" | tee -a "$LOG_FILE"
        echo -e "${RED}${nginx_code}${NC}      ${DIM}${gw_code}${NC}    ${DIM}${gw_ms}ms${NC}   ${local_status}" \
          | tee -a "$LOG_FILE"
        trap_summary
        ;;
      WAITING)
        local_status="${YELLOW}⏳ waiting${NC}"
        ;;
    esac

    # Color code http codes
    [[ "$nginx_code" == "200" ]] && nc_str="${GREEN}${nginx_code}${NC}" \
      || nc_str="${RED}${nginx_code}${NC}"
    [[ "$gw_code" == "200" ]]    && gc_str="${GREEN}${gw_code}${NC}" \
      || gc_str="${RED}${gw_code}${NC}"

    printf "  %-8s  %-6s  %-25s  " "$now" "$CURRENT_PHASE" "gpen.local${p}" | tee -a "$LOG_FILE"
    echo -e "${nc_str}      ${gc_str}    ${DIM}${gw_ms}ms${NC}   ${local_status}   ${DIM}${gw_body:0:35}${NC}" \
      | tee -a "$LOG_FILE"
  done

  TOTAL_CHECKS=$(( TOTAL_CHECKS + 1 ))
  check_count=$(( check_count + 1 ))
  [[ $(( check_count % 20 )) -eq 0 ]] && { print_stats; check_count=0; }

  sleep "$INTERVAL"
done
