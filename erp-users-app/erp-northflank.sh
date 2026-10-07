#!/usr/bin/env bash
# =============================================================================
# 3-Tier ERP on Northflank (Git + container pipeline)
#
#   Internet -> erp-web  public nginx reverse proxy  (2 replicas, port 80)
#            -> erp-app  Next.js 14 + Prisma + Auth  (2 replicas, port 3000, private)
#            -> erp-db   managed PostgreSQL 16        (internal only)
#
# Usage:
#   NF_TOKEN=... ./erp-northflank.sh create     # provision everything
#   NF_TOKEN=... ./erp-northflank.sh configure  # (re)apply config, idempotent
#   NF_TOKEN=... ./erp-northflank.sh build      # trigger and follow the app build
#   NF_TOKEN=... ./erp-northflank.sh status     # services, builds, endpoint
#   NF_TOKEN=... ./erp-northflank.sh destroy    # delete the whole project
# =============================================================================
set -euo pipefail

: "${NF_TOKEN:?Set NF_TOKEN (Northflank API token)}"

PROJECT="${PROJECT:-erp-3tier}"
REGION="${REGION:-europe-west}"
PLAN="${PLAN:-nf-compute-10}"
DB_PLAN="${DB_PLAN:-nf-compute-20}"
DB_STORAGE_MB="${DB_STORAGE_MB:-4096}"
GIT_REPO="${GIT_REPO:-https://github.com/wcm24b126-hue/3-erp-system}"
GIT_BRANCH="${GIT_BRANCH:-main}"
WEB_URL="${WEB_URL:-https://http--erp-web--4ygqv656w8vh.code.run}"
AUTH_SECRET="${AUTH_SECRET:-49QF0dmPQrlwr+mSP3FzKFs5SDUp5IQtkkrOoKXEmVA=}"

APP_PORT=3000
WEB_PORT=80
API="https://api.northflank.com/v1"
NGINX_CONF="$(cd "$(dirname "$0")" && pwd)/web/nginx.conf"

# ---- Helpers ----------------------------------------------------------------
call() {
  local method="$1" path="$2" body="${3:-}" out code
  if [[ -n "$body" ]]; then
    out=$(curl -sS -w '\n%{http_code}' -X "$method" "$API$path" \
      -H "Authorization: Bearer $NF_TOKEN" -H "Content-Type: application/json" -d "$body")
  else
    out=$(curl -sS -w '\n%{http_code}' -X "$method" "$API$path" \
      -H "Authorization: Bearer $NF_TOKEN" -H "Content-Type: application/json")
  fi
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ "$code" -ge 300 ]]; then
    echo "ERROR $code on $method $path" >&2
    echo "$out" >&2
    return 1
  fi
  echo "$out"
}

step() { echo; echo "==> $*"; }

exists() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $NF_TOKEN" "$API$1")" == "200" ]]
}

ensure() {
  local label="$1" getp="$2" postp="$3" body="$4"
  if exists "$getp"; then
    echo "    $label exists, skipping create"
  else
    call POST "$postp" "$body" >/dev/null
    echo "    $label created"
  fi
}

# ---- Tier 3: database -------------------------------------------------------
ensure_db() {
  step "Tier 3: PostgreSQL addon (erp-db)"
  ensure "addon erp-db" "/projects/$PROJECT/addons/erp-db" "/projects/$PROJECT/addons" "$(jq -n \
    --arg plan "$DB_PLAN" --argjson st "$DB_STORAGE_MB" \
    '{name:"erp-db", description:"ERP database", type:"postgresql", version:"16",
      billing:{deploymentPlan:$plan, storage:$st, replicas:1},
      tlsEnabled:true, externalAccessEnabled:false}')"
}

# ---- Secrets: DATABASE_URL (from addon) + NextAuth keys + public URL --------
configure_secrets() {
  step "Secrets: erp-secrets (DATABASE_URL + auth)"
  local body
  body=$(jq -n --arg auth "$AUTH_SECRET" --arg url "$WEB_URL" \
    '{description:"ERP database & auth secrets",
      secretType:"environment-arguments",
      priority:10,
      restrictions:{restricted:false, nfObjects:[], tags:[], tagMatchCondition:"or", stageIds:[]},
      addonDependencies:[{addonId:"erp-db", keys:[{keyName:"POSTGRES_URI", aliases:["DATABASE_URL"]}]}],
      secrets:{variables:{
        AUTH_SECRET:$auth,
        NEXTAUTH_SECRET:$auth,
        AUTH_TRUST_HOST:"true",
        AUTH_URL:$url,
        NEXTAUTH_URL:$url
      }}}')
  if exists "/projects/$PROJECT/secrets/erp-secrets"; then
    call PATCH "/projects/$PROJECT/secrets/erp-secrets" "$body" >/dev/null
    echo "    erp-secrets updated"
  else
    call POST "/projects/$PROJECT/secrets" "$body" >/dev/null
    echo "    erp-secrets created"
  fi
}

# ---- Tier 2: app ------------------------------------------------------------
ensure_app() {
  step "Tier 2: app service (erp-app, private Next.js)"
  ensure "service erp-app" "/projects/$PROJECT/services/erp-app" "/projects/$PROJECT/services/combined" "$(jq -n \
    --arg repo "$GIT_REPO" --arg branch "$GIT_BRANCH" --arg plan "$PLAN" --argjson port "$APP_PORT" \
    '{name:"erp-app", description:"ERP App Tier (Next.js 14, Prisma, NextAuth)",
      billing:{deploymentPlan:$plan},
      deployment:{instances:2},
      vcsData:{projectUrl:$repo, projectBranch:$branch, projectType:"github"},
      buildSettings:{dockerfile:{dockerFilePath:"/Dockerfile", dockerWorkDir:"/"}},
      ports:[{name:"http", internalPort:$port, public:false, vpcAccessible:false, protocol:"HTTP"}]}')"
}

configure_app() {
  step "App config: private port + health checks"
  local body
  body=$(jq -n --argjson port "$APP_PORT" \
    '{description:"ERP App Tier (Next.js 14, Prisma, NextAuth)",
      ports:[{name:"http", internalPort:$port, public:false, vpcAccessible:false, protocol:"HTTP",
              security:{credentials:[], policies:[], sso:{}}}],
      healthChecks:[
        {protocol:"HTTP", type:"startupProbe", path:"/api/health", port:$port,
         initialDelaySeconds:5, periodSeconds:10, timeoutSeconds:5, failureThreshold:30},
        {protocol:"HTTP", type:"readinessProbe", path:"/api/health", port:$port,
         initialDelaySeconds:1, periodSeconds:10, timeoutSeconds:5, failureThreshold:3, successThreshold:1},
        {protocol:"HTTP", type:"livenessProbe", path:"/api/health", port:$port,
         initialDelaySeconds:15, periodSeconds:20, timeoutSeconds:5, failureThreshold:3}
      ]}')
  call PATCH "/projects/$PROJECT/services/combined/erp-app" "$body" >/dev/null
  echo "    erp-app configured"
}

# ---- Tier 1: web ------------------------------------------------------------
ensure_web() {
  step "Tier 1: web service (erp-web, public reverse proxy)"
  ensure "service erp-web" "/projects/$PROJECT/services/erp-web" "/projects/$PROJECT/services/deployment" "$(jq -n \
    --arg plan "$PLAN" --argjson port "$WEB_PORT" \
    '{name:"erp-web", description:"ERP Web Tier (public nginx reverse proxy)",
      billing:{deploymentPlan:$plan},
      deployment:{instances:2, external:{imagePath:"nginx:alpine"}},
      ports:[{name:"http", internalPort:$port, public:true, vpcAccessible:false, protocol:"HTTP"}]}')"
}

configure_web() {
  step "Web config: nginx reverse proxy -> erp-app:$APP_PORT"
  [[ -f "$NGINX_CONF" ]] || { echo "ERROR: $NGINX_CONF not found" >&2; return 1; }
  local b64 body
  b64=$(base64 < "$NGINX_CONF" | tr -d '\n')
  body=$(jq -n --arg b64 "$b64" --argjson port "$WEB_PORT" \
    '{description:"ERP Web Tier (public nginx reverse proxy)",
      deployment:{
        type:"deployment",
        instances:2,
        external:{imagePath:"nginx:alpine"},
        docker:{configType:"default"},
        storage:{ephemeralStorage:{storageSize:1024}, shmSize:64}
      },
      ports:[{name:"http", internalPort:$port, public:true, vpcAccessible:false, protocol:"HTTP",
              security:{credentials:[], policies:[], sso:{}}}],
      runtimeFiles:{"/etc/nginx/conf.d/default.conf":{data:$b64, encoding:"utf-8"}},
      healthChecks:[
        {protocol:"HTTP", type:"startupProbe", path:"/api/health", port:$port,
         initialDelaySeconds:5, periodSeconds:10, timeoutSeconds:5, failureThreshold:18},
        {protocol:"HTTP", type:"readinessProbe", path:"/api/health", port:$port,
         initialDelaySeconds:1, periodSeconds:10, timeoutSeconds:5, failureThreshold:3, successThreshold:1}
      ]}')
  call PATCH "/projects/$PROJECT/services/deployment/erp-web" "$body" >/dev/null
  echo "    erp-web configured (nginx conf mounted, IP allowlist cleared)"
}

# ---- Build / status ---------------------------------------------------------
trigger_build() {
  step "Triggering build for erp-app (branch: $GIT_BRANCH)"
  call POST "/projects/$PROJECT/services/erp-app/build" "{}" >/dev/null
  echo "    build started"
}

follow_build() {
  local status concluded msg i=0
  while :; do
    status=$(call GET "/projects/$PROJECT/services/erp-app/build" |
      jq -r '.data.builds[0] | "\(.status) \(.concluded)"' 2>/dev/null || echo "UNKNOWN false")
    concluded="${status##* }"
    status="${status% *}"
    echo "    build: ${status:-UNKNOWN}"
    [[ "$concluded" == "true" ]] && break
    i=$((i + 1))
    if [[ $i -ge 90 ]]; then echo "    timed out waiting for build" >&2; return 1; fi
    sleep 10
  done
  msg=$(call GET "/projects/$PROJECT/services/erp-app/build" |
    jq -r '.data.builds[0] | "\(.status): \(.message // "ok")"')
  echo "    $msg"
  [[ "$msg" == SUCCESS:* ]]
}

show_status() {
  step "Project: $PROJECT"
  curl -sS -H "Authorization: Bearer $NF_TOKEN" "$API/projects/$PROJECT" |
    jq -r '.data | "  region: \(.region // "n/a")"'
  echo "  services:"
  curl -sS -H "Authorization: Bearer $NF_TOKEN" "$API/projects/$PROJECT/services" |
    jq -r '.data.services[] | "    \(.name): build=\(.status.build.status // "-") deploy=\(.status.deployment.status // "-")"'
  echo "  addons:"
  curl -sS -H "Authorization: Bearer $NF_TOKEN" "$API/projects/$PROJECT/addons" |
    jq -r '.data.addons[] | "    \(.name): \(.status)"'
  echo "  builds (erp-app):"
  curl -sS -H "Authorization: Bearer $NF_TOKEN" "$API/projects/$PROJECT/services/erp-app/build" |
    jq -r '.data.builds[0:3][] | "    \(.status) sha=\(.sha // "-") \(.message // "")"'
  echo "  endpoint: $WEB_URL"
}

create_all() {
  step "1/6 Project: $PROJECT"
  ensure "project $PROJECT" "/projects/$PROJECT" "/projects" "$(jq -n \
    --arg n "$PROJECT" --arg r "$REGION" \
    '{name:$n, region:$r, description:"3-tier ERP"}')"
  ensure_db
  configure_secrets
  ensure_app
  configure_app
  ensure_web
  configure_web
  trigger_build
  echo
  echo "Setup applied. Follow the build with: $0 build"
}

destroy_all() {
  step "Deleting project $PROJECT"
  read -r -p "Type project name '$PROJECT' to confirm destruction: " ans
  [[ "$ans" == "$PROJECT" ]] || { echo "Cancelled."; exit 1; }
  call DELETE "/projects/$PROJECT" >/dev/null
  echo "Project destroyed."
}

case "${1:-}" in
  create)   create_all ;;
  configure) ensure_db; configure_secrets; ensure_app; configure_app; ensure_web; configure_web ;;
  build)    trigger_build; follow_build ;;
  status)   show_status ;;
  destroy)  destroy_all ;;
  *) echo "Usage: $0 {create|configure|build|status|destroy}"; exit 1 ;;
esac
