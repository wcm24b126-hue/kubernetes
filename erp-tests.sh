#!/usr/bin/env bash
# =============================================================================
# Load balancing / fault tolerance / performance tests for the erp-web service
#
# Prerequisite: erp-web must run an image that prints its instance name,
# e.g. traefik/whoami (port 80). With plain nginx you cannot see which
# instance answered.
#
# Usage:
#   export URL="https://your-erp-web-public-url"     # from the Northflank UI
#   ./erp-tests.sh lb               # test 1: is traffic spread over instances?
#   ./erp-tests.sh failover 90      # test 2: watch availability for 90 s
#   ./erp-tests.sh load             # test 3: throughput and latency (needs ab)
#   ./erp-tests.sh all
#
# Run from the allowed office IP, otherwise you will get 403 (the IP policy).
# =============================================================================
set -uo pipefail
: "${URL:?Set URL to the public URL of erp-web}"

hr() { printf '\n%s\n' "=============== $* ==============="; }

preflight() {
  hr "PREFLIGHT CHECK"
  echo "URL = $URL"
  local code
  code=$(curl -4 -s -m 10 -o /tmp/erp_pre -w '%{http_code}' "$URL") || code="000"
  echo "HTTP status: $code"
  echo "First bytes of response:"; head -c 300 /tmp/erp_pre 2>/dev/null; echo
  case "$code" in
    000) echo "PROBLEM: no connection. Wrong URL, service not running, or no network."
         echo "  Check the URL in the Northflank UI (erp-web -> public URL) and that it includes https://"; return 1 ;;
    403|401) echo "PROBLEM: blocked by the IP policy. Your current IPv4 is: $(curl -4 -s -m 5 https://api.ipify.org)"
         echo "  Update the allowed address on the erp-web port in the Northflank UI."; return 1 ;;
    200) if grep -qi '^Hostname:' /tmp/erp_pre; then echo "OK: service answers and prints Hostname."
         else echo "PROBLEM: service answers, but the image is not traefik/whoami (no Hostname line)."
              echo "  Change the erp-web image to traefik/whoami (port 80) in the UI and wait until it runs."; return 1; fi ;;
    *) echo "PROBLEM: unexpected status $code. Check the service logs in the Northflank UI."; return 1 ;;
  esac
}

test_lb() {
  preflight || return 1
  hr "TEST 1: LOAD BALANCING (60 requests)"
  local out
  out=$(for _ in $(seq 1 60); do
    curl -4 -s -m 5 "$URL" | grep -m1 -i '^Hostname:' || echo "Hostname: ERROR/no-response"
  done | sort | uniq -c)
  echo "$out"
  local n
  n=$(echo "$out" | grep -vc ERROR)
  echo
  if (( n >= 2 )); then
    echo "PASS: $n different instances answered, so traffic is being balanced."
  else
    echo "FAIL/INCONCLUSIVE: only $n instance answered. Check replicas = 2 and that the image prints Hostname."
  fi
}

test_failover() {
  preflight || return 1
  local dur="${1:-90}"
  hr "TEST 2: FAULT TOLERANCE (monitoring for ${dur}s)"
  echo "While this runs, in the Northflank UI do ONE of these on erp-web:"
  echo "  a) scale instances from 2 to 1      (simulates losing a node)"
  echo "  b) restart the service / delete one instance, if offered"
  echo "  c) then scale back to 2 and watch it recover"
  echo "Time | HTTP code | Instance"
  local ok=0 bad=0 end=$((SECONDS + dur)) last="" code host line
  while (( SECONDS < end )); do
    line=$(curl -4 -s -m 2 -o /tmp/erp_body -w '%{http_code}' "$URL") || line="000"
    code="$line"
    host=$(grep -m1 -i '^Hostname:' /tmp/erp_body 2>/dev/null | awk '{print $2}')
    if [[ "$code" == "200" ]]; then ok=$((ok+1)); else bad=$((bad+1)); fi
    if [[ "$code-$host" != "$last" ]]; then
      printf '%s | %s | %s\n' "$(date +%T)" "$code" "${host:-none}"
      last="$code-$host"
    fi
    sleep 0.5
  done
  echo
  echo "Requests OK: $ok   Failed: $bad"
  if (( bad == 0 )); then echo "RESULT: no downtime observed."
  else echo "RESULT: $bad failed requests (a few during a failure can be normal; long runs mean no real redundancy)."; fi
}

test_load() {
  hr "TEST 3: LOAD / PERFORMANCE"
  if ! command -v ab >/dev/null; then
    echo "ab not installed. Run: sudo apt install -y apache2-utils"; return 1
  fi
  echo "-- warm-up --"; ab -q -n 200 -c 10 "$URL/" >/dev/null 2>&1
  for c in 10 50 100; do
    echo; echo "-- 2000 requests, concurrency $c --"
    ab -q -n 2000 -c "$c" "$URL/" 2>/dev/null | \
      grep -E 'Requests per second|Time per request.*mean\)|Failed requests|50%|95%|99%|Non-2xx'
  done
  echo
  echo "Note: results depend on your internet link and the small free plan (CPU/RAM)."
}

case "${1:-}" in
  lb) test_lb ;;
  failover) test_failover "${2:-90}" ;;
  load) test_load ;;
  all) test_lb; test_load; test_failover "${2:-90}" ;;
  *) echo "Usage: $0 {lb|failover [seconds]|load|all}"; exit 1 ;;
esac
