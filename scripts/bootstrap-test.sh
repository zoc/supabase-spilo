#!/usr/bin/env bash
# Run the real bootstrap inside the image and check what it produced.
#
# This is the test that catches a new upstream migration breaking the schema
# build -- the smoke test only proves the extensions load. Without it a
# Renovate bump of SUPABASE_POSTGRES_REF goes green in CI and fails at deploy,
# which is how the missing `pgbouncer` role was originally found.
#
# Runs scripts/supabase_post_init.sh exactly as Patroni does: same arguments,
# same secret directory, every phase, ON_ERROR_STOP throughout.
#
#   ./scripts/bootstrap-test.sh [image]

set -euo pipefail

IMAGE="${1:-supabase-spilo:local}"
PGVERSION="${PGVERSION:-18}"
NAME="supabase-spilo-bootstrap-$$"

PRELOAD="bg_mon,pg_stat_statements,pgextwlist,pg_auth_mon,set_user,timescaledb,pg_cron,pg_stat_kcache,pg_net,pgsodium,supautils,pg_tle"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting $IMAGE"
docker run -d --name "$NAME" -u postgres --entrypoint bash "$IMAGE" -c 'sleep 900' >/dev/null

docker exec "$NAME" bash -euo pipefail -c "
export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH
initdb -D /tmp/d -U postgres >/dev/null 2>&1
cat >> /tmp/d/postgresql.conf <<EOF
shared_preload_libraries = '${PRELOAD}'
pgsodium.getkey_script = '/usr/share/postgresql/${PGVERSION}/extension/pgsodium_getkey'
wal_level = logical
EOF
pg_ctl -D /tmp/d -l /tmp/log -o '-k /tmp -p 5432' start >/dev/null 2>&1 || { cat /tmp/log; exit 1; }
sleep 5

# Spilo's own post_init runs before ours on a real cluster and creates the
# roles the later phases re-grant to. Stand in for the parts that matter.
psql -h /tmp -U postgres -q -c \"create role admin createdb\" || true

# Spilo also puts monitoring views in public and grants them to PUBLIC, which
# is what phase 4 exists to undo. Recreate that here, or the revoke is silently
# untested (to_regclass finds nothing and the phase skips).
psql -h /tmp -U postgres -q -c 'create extension if not exists pg_stat_statements schema public'
psql -h /tmp -U postgres -q -c 'grant select on public.pg_stat_statements to public'

# Secrets reach the bootstrap as files, never env -- Spilo's runit unit scrubs
# the environment before exec'ing Patroni.
mkdir -p /tmp/secrets
echo -n 'bootstrap-test-password' > /tmp/secrets/password
echo -n 'bootstrap-test-jwt-secret-at-least-32-chars' > /tmp/secrets/jwtSecret

export SUPABASE_SECRET_DIR=/tmp/secrets
echo '==> running the bootstrap as Patroni does'
/scripts/supabase_post_init.sh admin 'host=/tmp port=5432 dbname=postgres user=postgres' \
  | tee /tmp/bootstrap.log

# Every vendored file must actually have run. This is what catches a new
# upstream migration being fetched but not executed -- a phase directory the
# script does not know about, or a name that sorts outside the glob.
on_disk=\$(find /supabase-migrations -name '*.sql' -type f | wc -l)
executed=\$(grep -cE '^\[supabase-init\]   ' /tmp/bootstrap.log)
echo \"==> \$executed of \$on_disk vendored SQL files executed\"
[ \"\$on_disk\" = \"\$executed\" ] || {
  echo \"FAIL: \$on_disk files on disk but \$executed ran -- something is not being picked up\"
  exit 1
}
"

echo
echo "==> checking what the bootstrap produced"
docker exec "$NAME" bash -euo pipefail -c "
export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH
q() { psql -h /tmp -U postgres -tAX -c \"\$1\"; }

fail=0
check() {  # check <label> <actual> <expected>
  if [ \"\$2\" = \"\$3\" ]; then printf '    ok   %-46s %s\n' \"\$1\" \"\$2\"
  else printf '    FAIL %-46s got %s want %s\n' \"\$1\" \"\$2\" \"\$3\"; fail=1; fi
}

# Every role Supabase's services actually authenticate as.
for r in supabase_admin supabase_auth_admin supabase_storage_admin supabase_functions_admin \
         authenticator anon authenticated service_role pgbouncer dashboard_user \
         supabase_read_only_user supabase_replication_admin; do
  check \"role \$r\" \"\$(q \"select count(*) from pg_roles where rolname='\$r'\")\" 1
done

for s in auth storage extensions graphql_public _realtime supabase_functions pgbouncer; do
  check \"schema \$s\" \"\$(q \"select count(*) from pg_namespace where nspname='\$s'\")\" 1
done

check 'auth.users exists'      \"\$(q \"select count(*) from pg_class where oid='auth.users'::regclass\")\" 1
check '_supabase database'     \"\$(q \"select count(*) from pg_database where datname='_supabase'\")\" 1
check 'supabase_admin is superuser' \"\$(q \"select rolsuper::text from pg_roles where rolname='supabase_admin'\")\" true

# The deviation this image makes on purpose -- assert it, so an upstream change
# that starts demoting postgres some other way is caught here.
check 'postgres still superuser' \"\$(q \"select rolsuper::text from pg_roles where rolname='postgres'\")\" true

# Every service role must have a password or nothing can log in. This is the
# failure mode that shipped silently once already.
check 'service roles have passwords' \"\$(q \"select count(*) from pg_authid where rolpassword is null and rolname in ('supabase_admin','supabase_auth_admin','supabase_storage_admin','authenticator','pgbouncer','supabase_functions_admin')\")\" 0

check 'jwt secret set on database' \"\$(q \"select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase where d.datname='postgres' and array_to_string(setconfig,',') like '%jwt_secret%'\")\" 1

# The PostgREST-critical setting; wrong here and every API request 500s.
check 'authenticator preloads supautils' \"\$(q \"select count(*) from pg_roles where rolname='authenticator' and array_to_string(rolconfig,',') like '%supautils%'\")\" 1

# 30-post: anon must not inherit Spilo's PUBLIC grant on pg_stat_statements.
if [ \"\$(q \"select count(*) from pg_class where relname='pg_stat_statements' and relnamespace='public'::regnamespace\")\" = '1' ]; then
  check 'anon cannot read pg_stat_statements' \"\$(q \"select has_table_privilege('anon','public.pg_stat_statements','SELECT')::text\")\" false
fi

[ \"\$fail\" = '0' ] || { echo; echo 'bootstrap produced an unexpected schema'; exit 1; }
"

echo
echo "==> bootstrap test passed for $IMAGE"
