#!/usr/bin/env bash
# Apply to an ALREADY-BOOTSTRAPPED database the migrations that have appeared
# in the image since it was bootstrapped, then bring extension versions up.
#
# The bootstrap (supabase_post_init.sh) only ever runs once, at initdb --
# Patroni invokes bootstrap.post_init nowhere else. So pulling a newer image
# gives an existing cluster new binaries and new SQL on disk, but leaves its
# schema exactly where it was. This closes that gap.
#
# Failure semantics: each migration runs in its own transaction with its
# tracking row written inside it, so a migration either fully applies and is
# recorded or does neither. On failure this stops at once and exits non-zero;
# migrations already applied stay applied, and a re-run resumes from the
# failure. It is deliberately NOT all-or-nothing -- a resumable partial
# upgrade beats an unresumable rollback, and some statements cannot be
# transactional anyway.
#
#   migrate.sh [--dry-run] [--baseline] [--skip-extensions]
#
# Connection comes from the standard libpq environment (PGHOST, PGUSER,
# PGPASSWORD, PGDATABASE...) or from $CONN.

set -euo pipefail

ROOT="${SUPABASE_MIGRATIONS_DIR:-/supabase-migrations}"
CONN="${CONN:-${PGDATABASE:-postgres}}"
DRY_RUN=0
BASELINE=0
SKIP_EXT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)          DRY_RUN=1 ;;
        --baseline)         BASELINE=1 ;;
        --skip-extensions)  SKIP_EXT=1 ;;
        -h|--help)          sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# shellcheck source=scripts/lib-migrate.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-migrate.sh"

log() { echo "[migrate] $*"; }
die() { echo "[migrate] $*" >&2; exit 1; }

# Refuse to touch a replica. The service in front of a Zalando cluster points
# at the leader, but a Job could be pointed anywhere.
[ "$(pgq 'SELECT pg_is_in_recovery()')" = "f" ] \
    || die "connected to a replica; point this at the leader (the <cluster> service, not <cluster>-repl)"

[ "$(pgq "SELECT count(*) FROM pg_namespace WHERE nspname = 'auth'")" = "1" ] \
    || die "no auth schema here -- this database was never bootstrapped by supabase-spilo"

# Only one of these at a time. Two Jobs racing would both compute the same
# delta and both try to apply it.
LOCK_KEY=8481963       # arbitrary, constant
[ "$(pgq "SELECT pg_try_advisory_lock(${LOCK_KEY})")" = "t" ] \
    || die "another migration run holds the advisory lock; refusing to run concurrently"

if ! tracking_exists; then
    if [ "$BASELINE" = "0" ]; then
        die "no ${TRACK_TABLE}: this database was bootstrapped by an image predating migration tracking.
Re-run with --baseline to adopt it, which records every file currently in the
image as already applied WITHOUT running it. That is only correct if this
database was bootstrapped from the SAME image ref, or a newer one. If the
image has moved on since, baseline first on the old image, then upgrade."
    fi
    log "adopting an untracked database (--baseline)"
fi
ensure_tracking

# ---------------------------------------------------------------- the delta
mapfile -t APPLIED < <(applied_set)
is_applied() {
    local key="$1" a
    for a in "${APPLIED[@]:-}"; do [ "$a" = "$key" ] && return 0; done
    return 1
}

# 40-reconcile is excluded on purpose: those files are applied on every run,
# not once, so they are never "pending" and are never recorded.
RECONCILE_DIR=40-reconcile

PENDING=()
for phase_dir in "$ROOT"/*/; do
    [ -d "$phase_dir" ] || continue
    phase="$(basename "$phase_dir")"
    [ "$phase" = "$RECONCILE_DIR" ] && continue
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        is_applied "${phase}/$(basename "$f")" || PENDING+=("${phase}|${f}")
    done < <(find "$phase_dir" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort)
done

# Phase order, then filename order within a phase -- the same order the
# bootstrap uses, so a delta lands exactly where it would have on a fresh
# cluster.
if [ ${#PENDING[@]} -gt 0 ]; then
    mapfile -t PENDING < <(printf '%s\n' "${PENDING[@]}" | LC_ALL=C sort)
fi

if [ "$BASELINE" = "1" ]; then
    log "baseline: recording ${#PENDING[@]} file(s) as applied WITHOUT running them"
    for entry in "${PENDING[@]:-}"; do
        [ -n "$entry" ] || continue
        phase="${entry%%|*}"; f="${entry#*|}"
        name="$(basename "$f")"; sha="$(sha256sum "$f" | cut -d' ' -f1)"
        [ "$DRY_RUN" = "1" ] && { log "  would baseline ${phase}/${name}"; continue; }
        pg -c "INSERT INTO ${TRACK_TABLE} (phase, filename, sha256)
               VALUES ('${phase}','${name}','${sha}')
               ON CONFLICT (phase, filename) DO NOTHING;"
        log "  baselined ${phase}/${name}"
    done
    log "done. Re-run without --baseline after updating the image to apply real deltas."
    exit 0
fi

# Upstream editing an already-applied migration in place would otherwise pass
# unnoticed; the checksum catches it. Reported, not fatal -- re-running an
# edited migration is usually wrong, and the operator should decide.
log "checking checksums of already-applied files"
DRIFT=0
while IFS='|' read -r phase name sha; do
    [ -n "${phase:-}" ] || continue
    f="$ROOT/$phase/$name"
    [ -f "$f" ] || { log "  WARNING ${phase}/${name} applied but no longer in the image"; DRIFT=1; continue; }
    now="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$now" = "$sha" ] || { log "  WARNING ${phase}/${name} changed upstream since it was applied"; DRIFT=1; }
done < <(pgq "SELECT phase || '|' || filename || '|' || sha256 FROM ${TRACK_TABLE}")
[ "$DRIFT" = "0" ] && log "  all match"

if [ ${#PENDING[@]} -eq 0 ]; then
    log "no pending migrations"
else
    log "${#PENDING[@]} pending migration(s)"
    for entry in "${PENDING[@]}"; do
        phase="${entry%%|*}"; f="${entry#*|}"
        if [ "$DRY_RUN" = "1" ]; then
            log "  would apply ${phase}/$(basename "$f")"
        else
            log "  applying ${phase}/$(basename "$f")"
            apply_file "$phase" "$f"
        fi
    done
fi

# ------------------------------------------------------------ reconciliation
# Spilo re-creates its objects in public on every promotion to primary, so this
# is re-applied here too -- an image roll may also have added new hardening
# that the running database has never seen.
if [ -d "$ROOT/$RECONCILE_DIR" ]; then
    log "reconciling (applied every run, never recorded)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            log "  would reconcile $(basename "$f")"
        else
            log "  $(basename "$f")"
            pg -f "$f"
        fi
    done < <(find "$ROOT/$RECONCILE_DIR" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort)
fi

# ------------------------------------------------------- extension versions
# Nothing updates these on its own -- not Postgres, not Patroni, not Spilo. A
# new image ships a new .so and a new SQL script while the catalog still
# describes the old version, so this has to be explicit.
if [ "$SKIP_EXT" = "0" ]; then
    log "checking extension versions"
    while IFS='|' read -r ext inst avail; do
        [ -n "${ext:-}" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            log "  would update ${ext}: ${inst} -> ${avail}"
        else
            log "  updating ${ext}: ${inst} -> ${avail}"
            pg -c "ALTER EXTENSION ${ext} UPDATE;" \
                || log "  WARNING ${ext} could not be updated; left at ${inst}"
        fi
    done < <(pgq "SELECT e.extname || '|' || e.extversion || '|' || a.default_version
                  FROM pg_extension e
                  JOIN pg_available_extensions a ON a.name = e.extname
                  WHERE a.default_version IS DISTINCT FROM e.extversion
                  ORDER BY e.extname")
fi

[ "$DRY_RUN" = "1" ] && { log "dry run; nothing was changed"; exit 0; }
log "applied $(pgq "SELECT count(*) FROM ${TRACK_TABLE}") file(s) total"
log "done"
