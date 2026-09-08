#!/usr/bin/env bash
#
# rag-callers.sh — summarise who is actually calling the internet-facing RAG
# and embedding endpoints, from Caddy's access log.
#
# Why this exists: as of 2026-09-08 four RAG API keys had no identifiable
# caller, because Caddy had no access logging at all. Logging was enabled that
# day. This script turns the log into the caller list that
# runbooks/rag-stack.md and decisions/rag-dev-key-gating.md are waiting on.
#
# Read-only. Prints a summary; changes nothing.
#
# Usage:
#   scripts/rag-callers.sh              # whole log
#   DAYS=7 scripts/rag-callers.sh       # last 7 days only
#
# Env:
#   CONTAINER  caddy container name            [caddy]
#   LOG        access log path in container    [/data/logs/access.log]
#   DAYS       only entries newer than N days  [all]

set -euo pipefail

CONTAINER="${CONTAINER:-caddy}"
LOG="${LOG:-/data/logs/access.log}"
DAYS="${DAYS:-}"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

if ! sudo docker exec "$CONTAINER" test -f "$LOG" 2>/dev/null; then
  echo "No access log at $LOG in container '$CONTAINER'."
  echo "Logging was enabled 2026-09-08; if this is empty the config may have"
  echo "been regenerated without the log directive -- check the Caddyfile and"
  echo "scripts/configure_dual_rag_route.sh (both were patched to preserve it)."
  exit 1
fi

SINCE=0
[ -n "$DAYS" ] && SINCE=$(( $(date +%s) - DAYS*86400 ))

# Read all log lines once; every summary below is computed from this.
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT
sudo docker exec "$CONTAINER" cat "$LOG" 2>/dev/null \
  | jq -c --argjson since "$SINCE" 'select(.ts >= $since)' > "$RAW" || true

TOTAL=$(wc -l < "$RAW" | tr -d ' ')
echo "=== Caddy access log summary ==="
echo "  entries: $TOTAL${DAYS:+  (last $DAYS days)}"
if [ "$TOTAL" = "0" ]; then
  echo "  Nothing logged yet. If this is soon after enabling logging, wait."
  exit 0
fi
echo "  window:  $(jq -rs 'if length>0 then (min_by(.ts).ts|strftime("%F %T")) else "-" end' "$RAW") .. $(jq -rs 'if length>0 then (max_by(.ts).ts|strftime("%F %T")) else "-" end' "$RAW")"

echo
echo "=== callers by source IP (top 25) ==="
jq -r '.request.client_ip // .request.remote_ip // "?"' "$RAW" \
  | sort | uniq -c | sort -rn | head -25 | awk '{printf "  %8s  %s\n",$1,$2}'

echo
echo "=== by host ==="
jq -r '.request.host // "?"' "$RAW" | sort | uniq -c | sort -rn \
  | awk '{printf "  %8s  %s\n",$1,$2}'

echo
echo "=== by status (401 = wrong or missing key) ==="
jq -r '.status // "?"' "$RAW" | sort | uniq -c | sort -rn \
  | awk '{printf "  %8s  %s\n",$1,$2}'

echo
echo "=== user agents (top 15) ==="
jq -r '(.request.headers["User-Agent"] // ["<none>"])[0]' "$RAW" \
  | sort | uniq -c | sort -rn | head -15 | awk '{c=$1;$1="";printf "  %8s %s\n",c,$0}'

echo
echo "=== paths (top 15) ==="
jq -r '.request.uri // "?"' "$RAW" | sort | uniq -c | sort -rn | head -15 \
  | awk '{printf "  %8s  %s\n",$1,$2}'

# Which backend served the request is the closest proxy for WHICH KEY was
# presented: Caddy routes per key to a different upstream. The log does not
# record the key itself (deliberately -- it is a secret), so upstream is the
# only available signal.
echo
echo "=== upstream served (proxy for which key was used) ==="
echo "    :8081 = RAG_API_KEY or RAG_V2_API_KEY   :8080 = RAG_LEGACY_API_KEY"
echo "    :8320 = cortex key                      (401 = no valid key)"
jq -r '(.resp_headers // {}) as $h | (.upstream // .request.uri // "?")' "$RAW" \
  2>/dev/null | sort | uniq -c | sort -rn | head -10 \
  | awk '{printf "  %8s  %s\n",$1,$2}' || echo "  (upstream not recorded in this log format)"

echo
echo "=== next step ==="
echo "  Replace the four 'unknown -- nobody knows' caller rows in"
echo "  runbooks/rag-stack.md with what the source IPs and user agents show."
echo "  Do NOT rotate any RAG key until that list exists (oncall.md B6)."
