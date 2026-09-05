#!/usr/bin/env bash
# Prove the upgrade path: bootstrap a database, then simulate a newer image
# arriving with extra migrations and check migrate.sh applies exactly those.
#
# This is the test for the failure mode that has no other guard -- the
# bootstrap runs once, so everything after it depends on migrate.sh being
# right.
#
#   ./scripts/upgrade-test.sh [image]

set -euo pipefail

IMAGE="${1:-supabase-spilo:local}"
PGVERSION="${PGVERSION:-18}"
NAME="supabase-spilo-upgrade-$$"

PRELOAD="bg_mon,pg_stat_statements,pgextwlist,pg_auth_mon,set_user,timescaledb,pg_cron,pg_stat_kcache,pg_net,pgsodium,supautils,pg_tle"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting $IMAGE"
docker run -d --name "$NAME" -u postgres --entrypoint bash "$IMAGE" -c 'sleep 900' >/dev/null

docker exec "$NAME" bash -euo pipefail -c "
export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH
initdb -D /tmp/d -U postgres >/dev/null 2>&1
{
  echo \"shared_preload_libraries = '${PRELOAD}'\"
  echo \"pgsodium.getkey_script = '/usr/share/postgresql/${PGVERSION}/extension/pgsodium_getkey'\"
} >> /tmp/d/postgresql.conf
pg_ctl -D /tmp/d -l /tmp/log -o '-k /tmp -p 5432' start >/dev/null 2>&1 || { cat /tmp/log; exit 1; }
sleep 5
psql -h /tmp -U postgres -q -c 'create role admin createdb' || true
mkdir -p /tmp/secrets
printf 'pw' > /tmp/secrets/password
printf 'jwtjwtjwtjwtjwtjwtjwtjwtjwtjwtjwt' > /tmp/secrets/jwtSecret
export SUPABASE_SECRET_DIR=/tmp/secrets
echo '==> bootstrapping'
/scripts/supabase_post_init.sh admin 'host=/tmp port=5432 dbname=postgres user=postgres' >/tmp/boot.log 2>&1 \
  || { tail -30 /tmp/boot.log; exit 1; }
grep -E 'recorded [0-9]+ applied files' /tmp/boot.log
"

echo
echo "==> simulating a newer image: two extra migrations appear"
docker exec "$NAME" bash -euo pipefail -c "
# Two files in two different phases, ordered so the later phase depends on the
# earlier one -- which also checks the delta is applied in phase order, not
# just filename order.
cat > /supabase-migrations/15-local/01_added_after_bootstrap.sql <<'SQL'
create table public.added_after_bootstrap(id int primary key);
insert into public.added_after_bootstrap values (1);
SQL
cat > /supabase-migrations/20-migrations/20270401120000_added_after_bootstrap.sql <<'SQL'
comment on table public.added_after_bootstrap is 'applied by the upgrade path';
SQL
"

echo "==> dry run first"
docker exec -e CONN='host=/tmp port=5432 dbname=postgres user=postgres' "$NAME" \
    bash -c "export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH; /scripts/migrate.sh --dry-run" \
    | sed 's/^/    /'

echo
echo "==> applying"
docker exec -e CONN='host=/tmp port=5432 dbname=postgres user=postgres' "$NAME" \
    bash -c "export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH; /scripts/migrate.sh" \
    | sed 's/^/    /'

echo
echo "==> checking the result"
docker exec "$NAME" bash -euo pipefail -c "
export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH
q() { psql -h /tmp -U postgres -tAX -c \"\$1\"; }
fail=0
check() {
  if [ \"\$2\" = \"\$3\" ]; then printf '    ok   %-48s %s\n' \"\$1\" \"\$2\"
  else printf '    FAIL %-48s got %s want %s\n' \"\$1\" \"\$2\" \"\$3\"; fail=1; fi
}

check 'new migration applied'      \"\$(q \"select count(*) from public.added_after_bootstrap\")\" 1
check 'later-phase file applied'    \"\$(q \"select obj_description('public.added_after_bootstrap'::regclass)\")\" 'applied by the upgrade path'
check 'both recorded'              \"\$(q \"select count(*) from supabase_spilo.applied_migrations where filename like '%added_after_bootstrap%'\")\" 2
check 'tracking not exposed to anon' \"\$(q \"select has_schema_privilege('anon','supabase_spilo','USAGE')::text\")\" false

# The point of the delta: nothing else should have re-run. auth.users would
# already exist and a re-run of the init-scripts would have errored, but assert
# the count explicitly so a silent double-apply is caught too.
# Reconcile files are excluded on both sides: they are applied on every run
# and never recorded, so counting them here would always be off by two.
on_disk=\$(find /supabase-migrations -name '*.sql' -type f -not -path '*/40-reconcile/*' | wc -l)
recorded=\$(q 'select count(*) from supabase_spilo.applied_migrations')
check 'recorded == migration files' \"\$recorded\" \"\$on_disk\"

# And the reconcile phase must have actually run, not merely been skipped.
check 'reconcile ran (logs out of public)' \"\$(q \"select count(*) from pg_class where relnamespace='public'::regnamespace and relname ~ '^postgres_log'\")\" 0

[ \"\$fail\" = '0' ] || exit 1
"

echo
echo "==> re-running must be a no-op (idempotent)"
docker exec -e CONN='host=/tmp port=5432 dbname=postgres user=postgres' "$NAME" \
    bash -c "export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH; /scripts/migrate.sh" \
    | grep -E 'no pending migrations|all match' | sed 's/^/    /'

echo
echo "==> a failing migration must stop, and stay resumable"
docker exec "$NAME" bash -c "cat > /supabase-migrations/15-local/02_broken.sql <<'SQL'
select * from a_table_that_does_not_exist;
SQL"
if docker exec -e CONN='host=/tmp port=5432 dbname=postgres user=postgres' "$NAME" \
      bash -c "export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH; /scripts/migrate.sh" >/tmp/fail.$$ 2>&1; then
    echo "    FAIL: a broken migration did not fail the run"; rm -f /tmp/fail.$$; exit 1
fi
echo "    ok   run exited non-zero"
rm -f /tmp/fail.$$
docker exec "$NAME" bash -euo pipefail -c "
export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH
n=\$(psql -h /tmp -U postgres -tAX -c \"select count(*) from supabase_spilo.applied_migrations where filename = '02_broken.sql'\")
[ \"\$n\" = '0' ] || { echo '    FAIL: the broken migration was recorded as applied'; exit 1; }
echo '    ok   broken migration not recorded, so a re-run retries it'
"

echo
echo "==> upgrade test passed for $IMAGE"
