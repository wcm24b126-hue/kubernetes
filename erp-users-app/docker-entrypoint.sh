#!/bin/sh
set -eu

PRISMA="node node_modules/prisma/build/index.js"

if [ -n "${DATABASE_URL:-}" ]; then
  db="$DATABASE_URL"
  case "$db" in
    *sslmode=*) ;;
    *\?*) db="${db}&sslmode=prefer" ;;
    *)    db="${db}?sslmode=prefer" ;;
  esac
  DATABASE_URL="$db"
  export DATABASE_URL

  echo "==> Syncing database schema (prisma db push)"
  i=1
  until $PRISMA db push --skip-generate --accept-data-loss; do
    if [ "$i" -ge 20 ]; then
      echo "ERROR: prisma db push failed after $i attempts" >&2
      exit 1
    fi
    echo "    attempt $i failed, retrying in 3s..."
    i=$((i + 1))
    sleep 3
  done
else
  echo "WARNING: DATABASE_URL is not set, skipping schema sync" >&2
fi

echo "==> Starting Next.js server on port ${PORT:-3000}"
HOSTNAME=0.0.0.0
export HOSTNAME
exec node server.js
