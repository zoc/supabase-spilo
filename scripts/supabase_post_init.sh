#!/bin/bash
# Runs the Supabase bootstrap from inside Patroni's bootstrap.post_init callback,
# appended to Spilo's own /scripts/post_init.sh.
#
# Spilo runs post_init.sh in TWO situations, not one:
#   - Patroni's bootstrap.post_init, once, after initdb; and
#   - its on_role_change callback (/scripts/on_role_change.sh), which execs
#     post_init.sh on EVERY promotion to primary.
# So this runs again after every failover and every restart of the leader. The
# migration phases are guarded to a fresh database; the reconcile phase runs
# every time on purpose, because Spilo's own post_init has just re-created and
# re-granted its objects and that has to be undone again afterwards.
#
#   $1  HUMAN_ROLE   (from Spilo's configured post_init arguments)
#   $2  connstring   (appended by Patroni)

set -euo pipefail

CONN="${2:-dbname=postgres}"
ROOT=/supabase-migrations

# shellcheck source=scripts/lib-migrate.sh
. /scripts/lib-migrate.sh

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

# The auth schema is the marker for "this database has already been built".
already_bootstrapped() {
    [ "$(psql -d "$CONN" -XtAc "SELECT count(*) FROM pg_namespace WHERE nspname='auth'")" != "0" ]
}

# Order matters: these are dbmate migrations, applied in filename order.
# Sorted explicitly under LC_ALL=C rather than left to glob expansion, which is
# locale-collated -- Spilo runs with LC_ALL=en_US.utf-8, where punctuation has
# variable collation weight. Today every upstream migration carries a
# fixed-width 14-digit timestamp so the two orders agree, but that is an
# implicit dependency on upstream's naming, and byte order costs nothing.
run_phase() {
    local dir="$1" label="$2" f
    [ -d "$ROOT/$dir" ] || { log "no $dir, skipping $label"; return 0; }
    log "--- $label ---"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        log "  $(basename "$f")"
        # Recorded as it goes, so migrate.sh can later work out the delta
        # against a newer image instead of re-running everything.
        apply_file "$dir" "$f"
    done < <(find "$ROOT/$dir" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort)
}

# Same as run_phase but without the bookkeeping: reconcile files are applied on
# every run by design, so recording them would be meaningless and would make
# migrate.sh believe they were already done.
run_phase_unrecorded() {
    local dir="$1" label="$2" f
    [ -d "$ROOT/$dir" ] || { log "no $dir, skipping $label"; return 0; }
    log "--- $label ---"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        log "  $(basename "$f")"
        psql -d "$CONN" -X -v ON_ERROR_STOP=1 -q -f "$f"
    done < <(find "$ROOT/$dir" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort)
}

if already_bootstrapped; then
    log "already bootstrapped; skipping the migration phases"
else
    ensure_tracking
    run_phase 00-pre-init     "phase 1: roles Spilo does not create"
    run_phase 10-init-scripts "phase 2: core schemas"
    run_phase 15-local        "phase 2b: local fixes over upstream init"
    run_phase 20-migrations   "phase 3: migrations"
    log "recorded $(pgq "SELECT count(*) FROM ${TRACK_TABLE}") applied files in ${TRACK_TABLE}"
fi

run_phase_unrecorded 40-reconcile "reconcile: undo what Spilo re-creates in public"

log "done"
