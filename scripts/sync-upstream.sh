#!/usr/bin/env bash
# Regenerate the vendored Supabase SQL from the refs pinned in upstream.env.
#
# Owns migrations/10-init-scripts and migrations/20-migrations completely and
# wipes them before refetching. Everything this repo authors itself lives in
# 00-pre-init, 15-local and 30-post, which are never touched.
#
#   ./scripts/sync-upstream.sh            refresh in place
#   ./scripts/sync-upstream.sh --check    fail if the tree is out of date (CI)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# shellcheck source=/dev/null
. "$ROOT/upstream.env"

PG_RAW="https://raw.githubusercontent.com/supabase/postgres/${SUPABASE_POSTGRES_REF}"
PG_API="https://api.github.com/repos/supabase/postgres/contents/migrations/db/migrations?ref=${SUPABASE_POSTGRES_REF}"
DK_RAW="https://raw.githubusercontent.com/supabase/supabase/${SUPABASE_DOCKER_SHA}/docker/volumes/db"

# demote-postgres is the one upstream migration this image must not apply:
# it runs ALTER ROLE postgres NOSUPERUSER, and on Spilo `postgres` is the role
# Patroni itself uses to manage the cluster (checkpoint, pg_rewind). The
# operator will not put it back either -- it treats postgres/standby as
# "system users" used only to build Secrets and leaves their attributes to
# Patroni (cluster.go, initSystemUsers). See README.
EXCLUDE='10000000000000_demote-postgres'

TARGET="$ROOT/migrations"
DEST_INIT="$TARGET/10-init-scripts"
DEST_MIG="$TARGET/20-migrations"

if [ "$CHECK" = "1" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    DEST_INIT="$WORK/10-init-scripts"
    DEST_MIG="$WORK/20-migrations"
fi

rm -rf "$DEST_INIT" "$DEST_MIG"
mkdir -p "$DEST_INIT" "$DEST_MIG"

curl_to() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }

echo "==> supabase/postgres @ ${SUPABASE_POSTGRES_REF}"
for f in 00000000000000-initial-schema \
         00000000000001-auth-schema \
         00000000000002-storage-schema \
         00000000000003-post-setup; do
    curl_to "$PG_RAW/migrations/db/init-scripts/$f.sql" "$DEST_INIT/$f.sql"
done

# The self-host compose layers these three over the init-scripts, in this order.
echo "==> supabase/supabase @ ${SUPABASE_DOCKER_SHA:0:12} (docker/volumes/db)"
curl_to "$DK_RAW/webhooks.sql" "$DEST_INIT/98-webhooks.sql"
curl_to "$DK_RAW/jwt.sql"      "$DEST_INIT/99-jwt.sql"
curl_to "$DK_RAW/roles.sql"    "$DEST_INIT/99-roles.sql"

echo "==> migration set"
names="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
           ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$PG_API" \
         | grep -o '"name": *"[^"]*\.sql"' | sed 's/.*: *"//;s/"$//' | sort)"
[ -n "$names" ] || { echo "could not list migrations at $SUPABASE_POSTGRES_REF" >&2; exit 1; }

count=0
for n in $names; do
    case "$n" in
        ${EXCLUDE}*) echo "    skip $n (see EXCLUDE above)"; continue ;;
    esac
    curl_to "$PG_RAW/migrations/db/migrations/$n" "$DEST_MIG/$n"
    count=$((count + 1))
done

# Ordered after the timestamped set: _supabase must exist before anything
# references it, and realtime.sql creates the schema realtime migrates into.
curl_to "$DK_RAW/_supabase.sql" "$DEST_MIG/zz-97-_supabase.sql"
curl_to "$DK_RAW/realtime.sql"  "$DEST_MIG/zz-99-realtime.sql"
count=$((count + 2))
echo "    $count files"

if [ "$CHECK" = "1" ]; then
    fail=0
    for d in 10-init-scripts 20-migrations; do
        if ! diff -ru "$TARGET/$d" "$WORK/$d" >/dev/null 2>&1; then
            echo
            echo "!! migrations/$d is out of date for the refs in upstream.env:"
            diff -ru "$TARGET/$d" "$WORK/$d" || true
            fail=1
        fi
    done
    [ "$fail" = "0" ] || {
        echo
        echo "Run ./scripts/sync-upstream.sh and commit the result." >&2
        exit 1
    }
    echo "==> vendored SQL matches upstream.env"
fi
