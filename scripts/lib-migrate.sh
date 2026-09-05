# shellcheck shell=bash
# Shared bookkeeping for the bootstrap (supabase_post_init.sh) and the
# upgrade path (migrate.sh). Sourced, never executed.
#
# Tracking lives in its own schema, NOT in public: public is the schema
# PostgREST exposes, so a table there would show up in the user's API and in
# Studio's table editor. dbmate's default public.schema_migrations would do
# exactly that, and auth/storage already keep their own tables in their own
# schemas for the same reason.

TRACK_SCHEMA=supabase_spilo
TRACK_TABLE="${TRACK_SCHEMA}.applied_migrations"

# psql that fails loudly. $CONN is set by the caller.
pg() { psql -d "$CONN" -X -v ON_ERROR_STOP=1 -q "$@"; }
pgq() { psql -d "$CONN" -X -tA -c "$1"; }

ensure_tracking() {
    # The IF NOT EXISTS notices are expected on every run after the first.
    pg <<SQL
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS ${TRACK_SCHEMA};
COMMENT ON SCHEMA ${TRACK_SCHEMA} IS
  'supabase-spilo bookkeeping. Not part of Supabase; safe to ignore.';

CREATE TABLE IF NOT EXISTS ${TRACK_TABLE} (
    phase       text        NOT NULL,
    filename    text        NOT NULL,
    sha256      text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (phase, filename)
);

-- Bookkeeping is nobody's business but the superuser's; in particular it must
-- not leak to the API roles the way Spilo's public views did.
REVOKE ALL ON SCHEMA ${TRACK_SCHEMA} FROM PUBLIC;
REVOKE ALL ON ${TRACK_TABLE} FROM PUBLIC;
SQL
}

# Some statements cannot run inside a transaction block, so those files are
# applied unwrapped and recorded immediately after. CREATE DATABASE is the one
# that actually occurs here (zz-97-_supabase.sql); the others are listed
# because they are the usual suspects and cost nothing to guard against.
needs_no_transaction() {
    grep -qiE '^[[:space:]]*(CREATE[[:space:]]+DATABASE|DROP[[:space:]]+DATABASE|ALTER[[:space:]]+SYSTEM|CREATE[[:space:]]+INDEX[[:space:]]+CONCURRENTLY|DROP[[:space:]]+INDEX[[:space:]]+CONCURRENTLY|VACUUM|REINDEX[[:space:]]+.*CONCURRENTLY)' "$1"
}

# apply_file <phase> <path>
#
# Applies one file and records it. Wrapped in a single transaction wherever
# possible, with the tracking INSERT inside it -- so a migration either fully
# applies AND is recorded, or does neither. Never half.
apply_file() {
    local phase="$1" path="$2"
    local name sha
    name="$(basename "$path")"
    sha="$(sha256sum "$path" | cut -d' ' -f1)"

    local record
    record="INSERT INTO ${TRACK_TABLE} (phase, filename, sha256)
            VALUES ('${phase}', '${name}', '${sha}')
            ON CONFLICT (phase, filename) DO UPDATE SET sha256 = EXCLUDED.sha256;"

    if needs_no_transaction "$path"; then
        # Cannot be atomic. Applied first, recorded second: a crash between the
        # two leaves it applied-but-unrecorded, which a re-run would retry.
        pg -f "$path"
        pg -c "$record"
    else
        {
            echo "BEGIN;"
            cat "$path"
            echo ";"
            echo "$record"
            echo "COMMIT;"
        } | pg -f -
    fi
}

# Files already recorded, as "phase/filename" lines.
applied_set() {
    pgq "SELECT phase || '/' || filename FROM ${TRACK_TABLE}" 2>/dev/null || true
}

tracking_exists() {
    [ "$(pgq "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = '${TRACK_SCHEMA}' AND c.relname = 'applied_migrations'" 2>/dev/null)" = "1" ]
}
