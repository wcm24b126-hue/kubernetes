#!/usr/bin/env bash
set -e

PROJECT_ID="erp-3tier"
SERVICE_ID="erp-app"
DB_ADDON="erp-db"
GIT_REPO="https://github.com/wcm24b126-hue/3-erp-system.git"
GIT_BRANCH="main"

echo "=== 1. Linking GitHub Repository & Build Config ==="
northflank update service deployment \
  --projectId "$PROJECT_ID" \
  --serviceId "$SERVICE_ID" \
  --gitUrl "$GIT_REPO" \
  --gitBranch "$GIT_BRANCH" \
  --buildType "dockerfile" \
  --dockerfilePath "/Dockerfile"

echo "=== 2. Setting Environment Variables & Linking Database ==="
northflank update service \
  --projectId "$PROJECT_ID" \
  --serviceId "$SERVICE_ID" \
  --secretGroup "$DB_ADDON" \
  --env DATABASE_URL='${POSTGRES_URI}' \
  --env NEXTAUTH_SECRET="49QF0dmPQrlwr+mSP3FzKFs5SDUp5IQtkkrOoKXEmVA=" \
  --env AUTH_SECRET="49QF0dmPQrlwr+mSP3FzKFs5SDUp5IQtkkrOoKXEmVA="

echo "=== 3. Starting Build and Deployment ==="
northflank start build \
  --projectId "$PROJECT_ID" \
  --serviceId "$SERVICE_ID"

echo "Deployment triggered. Run 'northflank get service --projectId $PROJECT_ID --serviceId $SERVICE_ID' to monitor progress."
