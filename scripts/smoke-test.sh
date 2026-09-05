#!/usr/bin/env bash
# Prove a built image actually works, rather than merely that it built.
#
# Starts a throwaway Postgres inside the image with the same
# shared_preload_libraries the Kubernetes manifests use, then checks that the
# preload set loads, every Supabase extension creates, pg_net can make a real
# HTTP request, and the session_preload_libraries setting that PostgREST
# depends on does not reject the connection.
#
#   ./scripts/smoke-test.sh [image]

set -euo pipefail

IMAGE="${1:-supabase-spilo:local}"
PGVERSION="${PGVERSION:-18}"
NAME="supabase-spilo-smoke-$$"

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

echo '--> server started; scanning log for failures'
if grep -iE 'FATAL|PANIC' /tmp/log; then echo 'FAIL: errors during startup'; exit 1; fi

echo '--> shared_preload_libraries loaded'
psql -h /tmp -U postgres -tAc \"select current_setting('shared_preload_libraries')\"

echo '--> creating extensions'
psql -h /tmp -U postgres -q -c 'create schema if not exists extensions'
for e in pgcrypto \\\"uuid-ossp\\\" pg_net pgsodium supabase_vault pg_graphql pgjwt pg_jsonschema wrappers pgmq index_advisor pg_tle pg_cron vector; do
  psql -h /tmp -U postgres -q -v ON_ERROR_STOP=1 -c \"create extension if not exists \$e cascade\" \
    || { echo \"FAIL: cannot create \$e\"; exit 1; }
done
psql -h /tmp -U postgres -c 'select extname, extversion from pg_extension order by extname'

echo '--> pg_net background worker is running'
psql -h /tmp -U postgres -tAc \"select backend_type from pg_stat_activity where backend_type like '%pg_net%'\" | grep -q pg_net \
  || { echo 'FAIL: pg_net worker absent'; exit 1; }

echo '--> authenticator can connect with supautils+safeupdate preloaded'
psql -h /tmp -U postgres -q -c 'create role authenticator login noinherit'
psql -h /tmp -U postgres -q -c 'alter role authenticator set session_preload_libraries = supautils, safeupdate'
psql -h /tmp -U authenticator -d postgres -tAc 'select 1' >/dev/null \
  || { echo 'FAIL: authenticator cannot connect -- preload library missing'; exit 1; }

echo '--> safeupdate is actually enforced'
psql -h /tmp -U postgres -q -c 'create table t(i int)'
psql -h /tmp -U postgres -q -c 'grant all on t to authenticator'
# Captured rather than piped: psql exits non-zero here by design, and under
# pipefail that would sink the pipeline even when the grep matches.
out=\"\$(psql -h /tmp -U authenticator -d postgres -q -c 'update t set i = 1' 2>&1 || true)\"
case \"\$out\" in
  *'requires a WHERE clause'*) echo '    refused UPDATE without WHERE, as expected' ;;
  *) echo \"FAIL: safeupdate not enforced -- got: \$out\"; exit 1 ;;
esac

echo '--> supautils GUCs registered'
psql -h /tmp -U postgres -tAc \"select count(*) from pg_settings where name like 'supautils.%'\" | grep -qv '^0\$' \
  || { echo 'FAIL: supautils not loaded'; exit 1; }
"

echo "==> pg_net live HTTP request"
docker exec "$NAME" bash -c "
export PATH=/usr/lib/postgresql/${PGVERSION}/bin:\$PATH
psql -h /tmp -U postgres -tAc \"select net.http_get('https://example.com')\" >/dev/null
sleep 8
psql -h /tmp -U postgres -tAc \"select status_code from net._http_response order by id desc limit 1\"
" | tee /tmp/net.$$ 
grep -qE '^(200|30[0-9])$' /tmp/net.$$ || { echo "FAIL: pg_net got no usable HTTP response"; rm -f /tmp/net.$$; exit 1; }
rm -f /tmp/net.$$

echo
echo "==> smoke test passed for $IMAGE"
