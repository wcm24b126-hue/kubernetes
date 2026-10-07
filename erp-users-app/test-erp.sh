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

# ------------------------------------------------------------------
# TEST 1: Database & Health / Server Connectivity
# ------------------------------------------------------------------
echo -e "\n--- Test 1: Connectivity Check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/login")
if [[ "$HTTP_CODE" == "200" ]]; then
  pass "Next.js server is up and accessible on $BASE_URL (HTTP $HTTP_CODE)"
else
  fail "Next.js server is down or returning unexpected code" "HTTP $HTTP_CODE"
fi

# ------------------------------------------------------------------
# TEST 2: Unauthenticated Protected Route Access (/dashboard)
# ------------------------------------------------------------------
echo -e "\n--- Test 2: Protected Route Guard (/dashboard) ---"
# Should redirect (302/307) or reject unauthenticated requests
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/dashboard")
if [[ "$HTTP_CODE" =~ ^(302|307|401|403)$ ]]; then
  pass "Unauthenticated access to /dashboard is blocked/redirected (HTTP $HTTP_CODE)"
else
  fail "Security risk: /dashboard allowed direct unauthenticated access" "HTTP $HTTP_CODE"
fi

# ------------------------------------------------------------------
# TEST 3: CSRF Token Extraction (for NextAuth)
# ------------------------------------------------------------------
echo -e "\n--- Test 3: Fetch NextAuth CSRF Token ---"
CSRF_JSON=$(curl -s -c "$COOKIE_JAR" "$BASE_URL/api/auth/csrf")
CSRF_TOKEN=$(echo "$CSRF_JSON" | grep -o '"csrfToken":"[^"]*' | cut -d'"' -f4)

if [[ -n "$CSRF_TOKEN" ]]; then
  pass "Successfully retrieved NextAuth CSRF token"
else
  fail "Could not fetch CSRF token from /api/auth/csrf" "$CSRF_JSON"
fi

# ------------------------------------------------------------------
# TEST 4: New User Registration (Server Action / Route)
# ------------------------------------------------------------------
echo -e "\n--- Test 4: User Registration Endpoint ---"
RANDOM_ID=$((RANDOM % 9000 + 1000))
TEST_EMAIL="testuser_${RANDOM_ID}@erp.local"
TEST_PASS="P@ssword_${RANDOM_ID}"

REG_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${BASE_URL}/api/register" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASS\",\"name\":\"Test User\"}")

STATUS=$(echo "$REG_RESPONSE" | grep "HTTP_STATUS" | cut -d':' -f2)
BODY=$(echo "$REG_RESPONSE" | grep -v "HTTP_STATUS")

if [[ "$STATUS" =~ ^(200|201|303)$ ]]; then
  pass "User registration succeeded for $TEST_EMAIL (HTTP $STATUS)"
else
  fail "Registration failed for $TEST_EMAIL" "HTTP $STATUS | Response: $BODY"
fi

# ------------------------------------------------------------------
# TEST 5: Duplicate Registration Check (Unique Constraint)
# ------------------------------------------------------------------
echo -e "\n--- Test 5: Duplicate Email Rejection ---"
DUP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${BASE_URL}/api/register" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASS\",\"name\":\"Duplicate User\"}")

DUP_STATUS=$(echo "$DUP_RESPONSE" | grep "HTTP_STATUS" | cut -d':' -f2)
DUP_BODY=$(echo "$DUP_RESPONSE" | grep -v "HTTP_STATUS")

if [[ "$DUP_STATUS" =~ ^(400|409|422)$ ]]; then
  pass "Duplicate email correctly rejected with client error (HTTP $DUP_STATUS)"
elif [[ "$DUP_STATUS" == "500" ]]; then
  fail "Unhandled Prisma P2002 error: Server crashed on duplicate email" "HTTP 500 | $DUP_BODY"
else
  fail "Unexpected status code on duplicate submission" "HTTP $DUP_STATUS | $DUP_BODY"
fi

# ------------------------------------------------------------------
# TEST 6: Authentication (NextAuth Credentials Callback)
# ------------------------------------------------------------------
echo -e "\n--- Test 6: NextAuth Credentials Login ---"
LOGIN_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -X POST "$BASE_URL/api/auth/callback/credentials" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "csrfToken=${CSRF_TOKEN}&email=${TEST_EMAIL}&password=${TEST_PASS}&json=true")

LOGIN_STATUS=$(echo "$LOGIN_RESPONSE" | grep "HTTP_STATUS" | cut -d':' -f2)
LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | grep -v "HTTP_STATUS")

if [[ "$LOGIN_STATUS" =~ ^(200|302)$ ]]; then
  pass "Login succeeded with valid credentials (HTTP $LOGIN_STATUS)"
else
  fail "Login failed with valid credentials" "HTTP $LOGIN_STATUS | Response: $LOGIN_BODY"
fi

# ------------------------------------------------------------------
# TEST 7: Access /dashboard with Authenticated Session
# ------------------------------------------------------------------
echo -e "\n--- Test 7: Authenticated Dashboard Access ---"
DASH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "$BASE_URL/dashboard")

if [[ "$DASH_STATUS" == "200" ]]; then
  pass "Dashboard loaded successfully with authenticated session cookie (HTTP 200)"
else
  fail "Authenticated request failed to access /dashboard" "HTTP $DASH_STATUS"
fi

echo "=========================================================="
echo "                    Test Run Complete                     "
echo "=========================================================="
