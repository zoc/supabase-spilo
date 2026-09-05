#!/bin/bash
# Runs the Supabase bootstrap from inside Patroni's bootstrap.post_init callback,
# appended to Spilo's own /scripts/post_init.sh.
#
# Patroni calls post_init once, on the leader, at initdb time only -- so this
# does not run on replicas or on restart. The auth-schema check below is belt
# and braces for a re-bootstrap onto a restored volume.
#
#   $1  HUMAN_ROLE   (from Spilo's configured post_init arguments)
#   $2  connstring   (appended by Patroni)

set -euo pipefail

CONN="${2:-dbname=postgres}"
ROOT=/supabase-migrations

# Secrets arrive as FILES, not env vars. Spilo's runit unit for Patroni
# (/etc/service/patroni/run) unsets everything outside a small allowlist --
# "We don't want accidentally disclose sensitive information" -- before it
# execs Patroni, so nothing put in the pod's spec.env survives to reach this
# script. A mounted Secret does.
SECRET_DIR="${SUPABASE_SECRET_DIR:-/etc/supabase-bootstrap}"
read_secret() {
    local f="$SECRET_DIR/$1"
    [ -r "$f" ] || { echo "[supabase-init] missing $f" >&2; exit 1; }
    tr -d '\r\n' < "$f"
}

# Consumed by psql \set ... `echo $VAR` in the upstream scripts.
#
# Assigned before export, deliberately: read_secret exits non-zero on a missing
# file, but that runs in a command substitution, so `export X="$(read_secret)"`
# takes the exit status of export (always 0) and set -e never fires. The
# bootstrap would then happily set every Supabase role's password to the empty
# string. Assigning first keeps the status, and :? catches an empty value.
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="$(read_secret password)"
JWT_SECRET="$(read_secret jwtSecret)"
JWT_EXP="${SUPABASE_JWT_EXP:-3600}"
export POSTGRES_USER
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?refusing to bootstrap with an empty db password}"
export JWT_SECRET="${JWT_SECRET:?refusing to bootstrap with an empty jwt secret}"
export JWT_EXP

# Spilo's post_init.sh exports search_path=pg_catalog, which breaks the
# upstream scripts' unqualified references once schemas start appearing.
export PGOPTIONS="-c synchronous_commit=local"

log() { echo "[supabase-init] $*"; }

if [ "$(psql -d "$CONN" -XtAc 'SELECT pg_is_in_recovery()')" = "t" ]; then
    log "on a replica, nothing to do"; exit 0
fi

if [ "$(psql -d "$CONN" -XtAc "SELECT count(*) FROM pg_namespace WHERE nspname='auth'")" != "0" ]; then
    log "auth schema already present, skipping"; exit 0
fi

run_phase() {
    local dir="$1" label="$2"
    [ -d "$ROOT/$dir" ] || { log "no $dir, skipping $label"; return 0; }
    log "--- $label ---"
    for f in "$ROOT/$dir"/*.sql; do
        [ -e "$f" ] || continue
        log "  $(basename "$f")"
        psql -d "$CONN" -X -v ON_ERROR_STOP=1 -q -f "$f"
    done
}

run_phase 00-pre-init     "phase 1: roles Spilo does not create"
run_phase 10-init-scripts "phase 2: core schemas"
run_phase 15-local        "phase 2b: local fixes over upstream init"
run_phase 20-migrations   "phase 3: migrations"
run_phase 30-post         "phase 4: zalando-side hardening"

log "done"
