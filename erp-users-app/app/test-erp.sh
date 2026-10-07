#!/usr/bin/env bash

BASE_URL="http://localhost:3000"
COOKIE_JAR="/tmp/erp_test_cookies.txt"
rm -f "$COOKIE_JAR"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1: $2"; }

echo "=========================================================="
echo "         Running Automated ERP App Test Cases             "
echo "=========================================================="

# Test 1: Connectivity
echo -e "\n--- Test 1: Connectivity Check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/login")
if [[ "$HTTP_CODE" == "200" ]]; then
  pass "Next.js server is up (HTTP 200)"
else
  fail "Next.js server is down" "HTTP $HTTP_CODE"
fi

# Test 2: Protected Route Guard
echo -e "\n--- Test 2: Protected Route Guard (/dashboard) ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/dashboard")
if [[ "$HTTP_CODE" =~ ^(302|307|401|403)$ ]]; then
  pass "Unauthenticated access to /dashboard is guarded (HTTP $HTTP_CODE)"
else
  fail "Security risk: /dashboard allowed direct access" "HTTP $HTTP_CODE"
fi

# Test 3: Fetch CSRF Token
echo -e "\n--- Test 3: Fetch NextAuth CSRF Token ---"
CSRF_JSON=$(curl -s -c "$COOKIE_JAR" "$BASE_URL/api/auth/csrf")
CSRF_TOKEN=$(echo "$CSRF_JSON" | grep -o '"csrfToken":"[^"]*' | cut -d'"' -f4)
if [[ -n "$CSRF_TOKEN" ]]; then
  pass "Retrieved CSRF token"
else
  fail "Could not fetch CSRF token" "$CSRF_JSON"
fi

# Test 4 & 5: Direct DB Seed / Auth Callback Test
RANDOM_ID=$((RANDOM % 9000 + 1000))
TEST_EMAIL="user_${RANDOM_ID}@erp.local"
TEST_PASS="Password123!"

echo -e "\n--- Test 4: Testing NextAuth Callback Directly ---"
LOGIN_RES=$(curl -s -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -X POST "$BASE_URL/api/auth/callback/credentials" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "csrfToken=${CSRF_TOKEN}&email=${TEST_EMAIL}&password=${TEST_PASS}&redirectTo=%2Fdashboard")

STATUS=$(echo "$LOGIN_RES" | grep "HTTP/" | head -n1 | awk '{print $2}')
if [[ "$STATUS" =~ ^(302|303)$ ]]; then
  pass "NextAuth Credentials Callback responded with redirect (HTTP $STATUS)"
else
  echo "$LOGIN_RES" | head -n 20
  fail "NextAuth Callback failed" "HTTP $STATUS"
fi

echo "=========================================================="
echo "                    Test Run Complete                     "
echo "=========================================================="
