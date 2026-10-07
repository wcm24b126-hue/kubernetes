#!/usr/bin/env bash
# =============================================================================
# erp-audit.sh : telemetry + vulnerability checks for the erp-web service
#
#   export URL="https://your-real-erp-web-url"
#   ./erp-audit.sh                 # everything except automatic failover
#   AUTO_FAILOVER=1 NF_TOKEN=... ./erp-audit.sh   # also scale 2 -> 1 -> 2 via API
#
# Optional tools (the script skips what is missing):
#   ab   : sudo apt install -y apache2-utils
#   wrk  : sudo apt install -y wrk
#   trivy: see trivy.dev (image vulnerability scan)
#
# Run only against services you own, from your allowed IP.
# Results are also saved to erp-audit-<timestamp>.txt
# =============================================================================
set -uo pipefail
: "${URL:?Set URL to the public URL of erp-web}"
URL="${URL%/}"
HOST="$(echo "$URL" | sed -E 's#^https?://##; s#/.*$##')"
PROJECT="${PROJECT:-erp-3tier}"
SERVICE="${SERVICE:-erp-web}"
SAMPLES="${SAMPLES:-100}"
SCAN_IMAGE="${SCAN_IMAGE:-traefik/whoami:latest}"
REPORT="erp-audit-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$REPORT") 2>&1

PASS=0; WARN=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [info] $*"; }
hr()   { printf '\n=============== %s ===============\n' "$*"; }
pctl() { sort -n | awk -v p="$1" '{a[NR]=$1} END{ if(NR==0){print "n/a"; exit}
         i=int(NR*p/100); if(i<NR*p/100) i++; if(i<1) i=1; printf "%.0f", a[i]*1000 }'; }
IS_HTTPS=0; [[ "$URL" == https://* ]] && IS_HTTPS=1
HDRS=/tmp/erp_audit_hdrs; BODY=/tmp/erp_audit_body

hr "0. ENVIRONMENT"
info "Time        : $(date -Is)"
info "Target      : $URL"
info "Your IPv4   : $(curl -4 -s -m 5 https://api.ipify.org || echo unknown)"
CODE=$(curl -4 -s -m 10 -D "$HDRS" -o "$BODY" -w '%{http_code}' "$URL/") || CODE=000
info "First request: HTTP $CODE"
if [[ "$CODE" != "200" ]]; then
  fail "Service did not return 200 (got $CODE). Fix URL/IP policy before auditing."
  exit 1
fi

# -----------------------------------------------------------------------------
hr "1. LATENCY TELEMETRY ($SAMPLES sequential requests)"
DATA=$(for _ in $(seq 1 "$SAMPLES"); do
  curl -4 -s -m 10 -o /dev/null \
    -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code}\n' "$URL/" || true
done)
OKN=$(echo "$DATA" | awk '$6==200' | wc -l)
BAD=$((SAMPLES-OKN))
echo "$DATA" | awk '{d+=$1; c+=$2; t+=$3; f+=$4; z+=$5; n++}
  END{ printf "  avg DNS %.0f ms | TCP connect %.0f ms | TLS done %.0f ms | first byte %.0f ms | total %.0f ms\n",
       d/n*1000, c/n*1000, t/n*1000, f/n*1000, z/n*1000 }'
P50=$(echo "$DATA" | awk '{print $5}' | pctl 50)
P95=$(echo "$DATA" | awk '{print $5}' | pctl 95)
P99=$(echo "$DATA" | awk '{print $5}' | pctl 99)
MAX=$(echo "$DATA" | awk '{print $5}' | pctl 100)
info "total time  : p50 ${P50} ms | p95 ${P95} ms | p99 ${P99} ms | max ${MAX} ms"
(( BAD == 0 )) && pass "0 failed of $SAMPLES requests" || fail "$BAD of $SAMPLES requests failed"
[[ "$P95" != "n/a" ]] && (( P95 < 1000 )) && pass "p95 latency under 1000 ms" || warn "p95 latency is 1000 ms or more"
info "Latency includes your home internet path to London; compare to a cloud VM in the same region for a fair baseline."

# -----------------------------------------------------------------------------
hr "2. LOAD BALANCING (60 requests)"
DIST=$(for _ in $(seq 1 60); do curl -4 -s -m 5 "$URL/" | grep -m1 -i '^Hostname:' || echo "Hostname: none"; done | sort | uniq -c)
echo "$DIST" | sed 's/^/  /'
NINST=$(echo "$DIST" | grep -vc 'none')
if (( NINST >= 2 )); then pass "$NINST instances answered"
elif echo "$DIST" | grep -q none; then warn "image does not print Hostname, cannot verify balancing"
else fail "only one instance answered"; fi

# -----------------------------------------------------------------------------
hr "3. THROUGHPUT / TPS"
GOT429=0
if command -v ab >/dev/null; then
  ab -q -n 200 -c 10 "$URL/" >/dev/null 2>&1
  for c in 10 50 100; do
    OUT=$(ab -q -k -l -n 2000 -c "$c" "$URL/" 2>/dev/null)
    RPS=$(echo "$OUT" | awk '/Requests per second/{print $4}')
    FAILS=$(echo "$OUT" | awk '/Failed requests/{print $3}')
    NON2=$(echo "$OUT" | awk '/Non-2xx/{print $3}')
    L95=$(echo "$OUT" | awk '$1=="95%"{print $2}')
    L99=$(echo "$OUT" | awk '$1=="99%"{print $2}')
    echo "  concurrency $c: ${RPS:-n/a} req/s | p95 ${L95:-n/a} ms | p99 ${L99:-n/a} ms | failed ${FAILS:-n/a} | non-2xx ${NON2:-0}"
    [[ "${NON2:-0}" != "0" ]] && GOT429=1
    [[ "${FAILS:-0}" == "0" ]] && pass "no failed requests at concurrency $c" || warn "failed requests at concurrency $c (${FAILS})"
  done
else
  warn "ab not installed (sudo apt install -y apache2-utils), skipped"
fi
if command -v wrk >/dev/null; then
  echo "  --- wrk 2 threads, 50 connections, 20 s ---"
  wrk -t2 -c50 -d20s --latency "$URL/" 2>&1 | grep -E 'Requests/sec|50%|90%|99%|Socket errors|Non-2xx' | sed 's/^/  /'
else
  info "wrk not installed (sudo apt install -y wrk), second tool skipped"
fi
info "Treat these numbers as the limit of the small plan (check CPU in the Northflank Metrics tab) plus your internet link."

# -----------------------------------------------------------------------------
hr "4. FAULT TOLERANCE"
if [[ "${AUTO_FAILOVER:-0}" == "1" && -n "${NF_TOKEN:-}" ]]; then
  LOG=/tmp/erp_audit_failover.log; : > "$LOG"
  scale() { curl -sS -o /dev/null -w '%{http_code}' -X POST \
      "https://api.northflank.com/v1/projects/$PROJECT/services/$SERVICE/scale" \
      -H "Authorization: Bearer $NF_TOKEN" -H "Content-Type: application/json" \
      -d "{\"instances\":$1}"; }
  monitor() { local end=$((SECONDS+$1)) code host
    while (( SECONDS < end )); do
      code=$(curl -4 -s -m 2 -o /tmp/erp_audit_mon -w '%{http_code}' "$URL/") || code=000
      host=$(grep -m1 -i '^Hostname:' /tmp/erp_audit_mon 2>/dev/null | awk '{print $2}')
      echo "$(date +%T) $code ${host:-none}" >> "$LOG"; sleep 0.5
    done; }
  info "Monitoring 110 s: scale to 1 instance at ~15 s, back to 2 at ~60 s"
  monitor 110 & MP=$!
  sleep 15; R1=$(scale 1); info "scale to 1 -> HTTP $R1"
  sleep 45; R2=$(scale 2); info "scale to 2 -> HTTP $R2"
  wait "$MP"
  TOT=$(wc -l < "$LOG"); OKF=$(awk '$2==200' "$LOG" | wc -l); BADF=$((TOT-OKF))
  info "answering instances over time:"
  awk '{print $3}' "$LOG" | uniq -c | sed 's/^/    /'
  (( BADF == 0 )) && pass "no failed requests during scale-down/up ($TOT requests)" \
                  || warn "$BADF of $TOT requests failed during scale changes"
  [[ "$R1" == "200" && "$R2" == "200" ]] || warn "scale API calls did not both return 200, check the Scale button manually"
else
  info "Skipped. For an automatic test: AUTO_FAILOVER=1 NF_TOKEN=... ./erp-audit.sh"
  info "Or run ./erp-tests.sh failover 120 and use the Scale button by hand."
fi

# -----------------------------------------------------------------------------
hr "5. SECURITY: TRANSPORT"
if (( IS_HTTPS )); then
  CERT=$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)
  echo "$CERT" | sed 's/^/  /'
  if curl -4 -s -m 8 --tlsv1.2 --tls-max 1.2 -o /dev/null "$URL/"; then pass "TLS 1.2 accepted"; else warn "TLS 1.2 not accepted"; fi
  if curl -4 -s -m 8 --tlsv1.3 -o /dev/null "$URL/"; then pass "TLS 1.3 accepted"; else warn "TLS 1.3 not accepted"; fi
  END=$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [[ -n "$END" ]] && (( $(date -d "$END" +%s) - $(date +%s) > 14*86400 )); then pass "certificate valid for more than 14 days"; else warn "certificate expires within 14 days or could not be read"; fi
  RC=$(curl -4 -s -m 8 -o /dev/null -w '%{http_code} %{redirect_url}' "http://$HOST/") || RC="000"
  info "http:// request -> $RC"
  case "$RC" in 301*|302*|307*|308*) pass "HTTP redirects to HTTPS";; 000*) pass "plain HTTP not served";; *) warn "plain HTTP is served without redirect";; esac
else
  warn "URL is not HTTPS, transport checks skipped"
fi

hr "6. SECURITY: HEADERS AND DISCLOSURE"
curl -4 -s -m 10 -D "$HDRS" -o "$BODY" "$URL/" >/dev/null
for h in strict-transport-security x-content-type-options x-frame-options content-security-policy referrer-policy permissions-policy; do
  grep -qi "^$h:" "$HDRS" && pass "header present: $h" || warn "header missing: $h"
done
for h in server x-powered-by x-aspnet-version; do
  V=$(grep -i "^$h:" "$HDRS" | tr -d '\r' | head -1)
  [[ -n "$V" ]] && warn "version/technology disclosure: $V"
done
if grep -qiE '^(Hostname|RemoteAddr|IP):' "$BODY"; then
  warn "response exposes internal details (hostname, pod IPs). Expected for the whoami test image; must NOT happen in the real ERP"
fi
TR=$(curl -4 -s -m 8 -o /dev/null -w '%{http_code}' -X TRACE "$URL/") || TR=000
if [[ "$TR" == "200" ]]; then
  if grep -qiE '^Hostname:' "$BODY"; then warn "TRACE returned 200, but this test image answers every method with 200 (re-test with the real app)"
  else fail "TRACE method enabled"; fi
else pass "TRACE not enabled ($TR)"; fi

hr "7. SECURITY: EXPOSED PATHS"
RND=$(curl -4 -s -m 8 -o /dev/null -w '%{http_code}' "$URL/zz-nonexistent-$RANDOM") || RND=000
if [[ "$RND" == "200" ]]; then
  warn "app answers 200 for any path (catch-all), path probing not meaningful for this image"
else
  for p in /.env /.git/HEAD /server-status /admin /actuator/env /phpinfo.php /backup.zip /config.json; do
    C=$(curl -4 -s -m 8 -o /dev/null -w '%{http_code}' "$URL$p") || C=000
    [[ "$C" == "200" ]] && fail "sensitive path reachable: $p" || pass "$p -> $C"
  done
fi

hr "8. SECURITY: ACCESS CONTROL"
if curl -6 -s -m 6 -o /dev/null "$URL/" 2>/dev/null; then
  C6=$(curl -6 -s -m 8 -o /dev/null -w '%{http_code}' "$URL/")
  [[ "$C6" == "200" ]] && fail "reachable over IPv6 with 200: the IPv4 allowlist can be bypassed" || pass "IPv6 request blocked ($C6)"
else
  pass "no IPv6 path to the service, or request failed (allowlist not bypassed this way)"
fi
(( GOT429 )) && pass "server returned non-2xx under load (possible rate limiting/shedding)" \
             || warn "no rate limiting observed under load (consider adding it for the real ERP)"
info "Manual: open the URL from a phone on mobile data (must be blocked); confirm erp-app and erp-db have no public address in their Networking tabs."

hr "9. SECURITY: CONTAINER IMAGE (Trivy)"
if command -v trivy >/dev/null; then
  trivy image --quiet --severity HIGH,CRITICAL "$SCAN_IMAGE" 2>&1 | tail -25 | sed 's/^/  /'
  info "Update base images/dependencies for any HIGH or CRITICAL findings."
else
  warn "trivy not installed (see trivy.dev), image scan skipped"
fi

# -----------------------------------------------------------------------------
hr "SUMMARY"
echo "  PASS: $PASS   WARN: $WARN   FAIL: $FAIL"
echo "  Report saved to: $REPORT"
echo "  Also check CPU and memory graphs in Northflank -> $SERVICE -> Metrics during the load test."
