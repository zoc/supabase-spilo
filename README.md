# supabase-spilo

> [!WARNING]
> **Homelab project. Barely tested. Use at your own risk — you can lose data with this.**
>
> This is a personal homelab experiment, published only in case it is useful to someone else. It is not a
> product, it is not supported, and it has never run in production — mine or anyone else's. There is no
> guarantee it ever will.
>
> **What has actually been exercised:** bootstrapping a fresh two-instance cluster on a *single-node local
> Kubernetes* (OrbStack), the REST / auth / storage / meta / studio endpoints answering through the gateway,
> RLS behaving, one Patroni failover and one switchover, and the CI smoke test on `linux/amd64` and
> `linux/arm64`.
>
> **What has not been tested at all:** any multi-node or production cluster; backup and restore (neither
> wal-g nor the operator's logical backups have ever been exercised against this image); sustained load or
> long-running operation; and Postgres major-version upgrades. In-place upgrades of an existing database have
> a mechanism (`scripts/migrate.sh`, see [Updating](#updating)) and a test, but have never been run against
> anything but a throwaway cluster.
>
> It also deliberately deviates from upstream Supabase in three places, one of which trades away in-cluster
> TLS. Read [Things that will bite you](#things-that-will-bite-you) before deploying it anywhere, and the
> [Caveats](#caveats) before storing anything in it.
>
> This is published under the Apache License 2.0. Sections 7 and 8 — no warranty, no liability — are not
> boilerplate here; take them literally. The author cannot be held responsible for any data loss, outage or
> other damage arising from its use. Do not point it at data you cannot afford to lose, and prove your
> restore path works before you trust it with anything.

Supabase's Postgres, rebuilt on [Zalando's Spilo](https://github.com/zalando/spilo) so it can run under the
[postgres-operator](https://github.com/zalando/postgres-operator) with Patroni replication and automatic failover,
instead of the single unmanaged container every self-host guide ships.

[![build](https://github.com/zoc/supabase-spilo/actions/workflows/build.yml/badge.svg)](https://github.com/zoc/supabase-spilo/actions/workflows/build.yml)

```text
docker.io/fzoc/supabase-spilo:18
```

`linux/amd64` and `linux/arm64`.

## Why

Supabase's own image is a single Postgres. Running it under a Postgres operator gets you replication, failover,
backups and monitoring for free — but the community Helm chart is explicit that it will not set up an external
database:

> when using an external database, it must already be initialized with the required Supabase schemas, roles and grants.
> The chart no longer runs automatic migrations against external databases.

This image is that initialisation, carried inside a Spilo base. It adds two things to stock Spilo:

1. **The Supabase extension set** — `pg_net`, `pg_graphql`, `supautils`, `safeupdate`, `pgsodium`, `supabase_vault`,
   `pgjwt`, `pg_jsonschema`, `wrappers`, `pgmq`, `pg_tle`, `index_advisor` — from the
   [Pigsty](https://pigsty.io) APT repository.
2. **The Supabase bootstrap SQL**, run by Patroni's `bootstrap.post_init` callback. Unlike CloudNativePG, Spilo does
   execute scripts from the image at bootstrap, so this needs no separate `Job` and has no ordering race with whatever
   deploys the rest of Supabase.

## Quick start

`examples/` holds a working pair: a `postgresql` custom resource and the values for the
[community Supabase chart](https://github.com/supabase-community/supabase-kubernetes) pointed at it.

```bash
kubectl apply -f examples/postgresql-supabase-db.yaml
helm install supabase supabase/supabase -f examples/supabase-values.yaml
```

Both carry comments explaining the settings that are not obvious. Read them before copying — particularly `pg_hba`.

## Things that will bite you

These are the non-obvious ones, all found the hard way.

### `spec.env` cannot reach the bootstrap

Spilo runs Patroni under runit, and `/etc/service/patroni/run` unsets every variable outside a small allowlist
before exec'ing it — *"We don't want accidentally disclose sensitive information"*. Nothing you put in the pod's
`spec.env` survives to `post_init`. Secrets must arrive as a **mounted file**; the example uses
`spec.additionalVolumes` to mount a `Secret` at `/etc/supabase-bootstrap`.

### Setting `shared_preload_libraries` makes you own the whole list

Spilo appends `timescaledb`, `pg_cron` and `pg_stat_kcache` to its own defaults **only while you have not set the key
yourself** (`configure_spilo.py`). The moment you set it, that append stops and anything you left out is silently
gone. The same applies to `extwlist.extensions`. The example manifest spells out the full list.

### `demote-postgres` is deliberately not applied

Upstream's `10000000000000_demote-postgres.sql` runs `ALTER ROLE postgres NOSUPERUSER`. On Spilo, `postgres` is the
role Patroni itself uses to manage the cluster, and the operator will not restore it — it treats `postgres` and
`standby` as system users whose attributes are Patroni's business, using its own definitions only to build `Secret`s.
`scripts/sync-upstream.sh` excludes that one migration, and `postgres` stays superuser.

This is the single deviation from upstream's privilege model. For a single-tenant deployment it is a fair trade; if
you intend to hand out database access, understand what you are giving up.

### The chart hardcodes `DB_SSL: disable`

Spilo's `pg_hba` is `hostnossl all all all reject`, so every service is rejected at connect time. The chart's
auth/rest/storage/meta templates hardcode `DB_SSL: disable` with no values hook. The example works around it on the
database side by relaxing `pg_hba` for the pod network — **which trades away in-cluster TLS**. The better fix is a
values-driven sslmode in the chart. Note also that `realtime` reads `DB_SSL` as a *boolean*, not an sslmode.

### `environment.<svc>` replaces, it does not merge

In the community chart, setting `environment.auth` discards the chart's defaults for that service rather than merging
into them. Dropping `GOTRUE_API_PORT` alone leaves GoTrue listening on `:8081` while the Service targets `9999`;
dropping `APP_NAME` crashes realtime at boot.

### Spilo's own objects live in `public`

Spilo creates 23 objects in `public` — log foreign tables, `failed_authentication_*`, `pg_stat_*` views — and `public`
is the schema PostgREST exposes. Four of them are granted `SELECT` to `PUBLIC`, which `anon` inherits, so they become
readable with nothing but the anon key. `migrations/30-post` revokes that. Note it must be a revoke **from `PUBLIC`**:
`anon` holds no direct grant, so revoking from `anon` is silently a no-op.

They are still *visible* in Studio's table editor, which is cosmetic but constant.

## How the bootstrap runs

`scripts/supabase_post_init.sh` is appended to Spilo's own `post_init.sh`, so Spilo's setup happens first. It runs on
the leader only, once, at initdb time, and is a no-op if the `auth` schema already exists.

| phase | source | what it does |
| --- | --- | --- |
| `00-pre-init` | this repo | `supabase_admin` and `pgbouncer`, which Supabase's platform creates outside the OSS migration set |
| `10-init-scripts` | upstream, vendored | the four init-scripts plus `webhooks`/`jwt`/`roles` from the monorepo's `docker/` |
| `15-local` | this repo | sets `supabase_admin`'s password — upstream's `roles.sql` never does, because in Supabase's image it is the initdb superuser and already has one |
| `20-migrations` | upstream, vendored | the dbmate migration set, minus `demote-postgres` |
| `30-post` | this repo | revokes the `PUBLIC` grants on Spilo's `pg_stat_*` views |

There is an ordering trap worth knowing: `20250312095419` re-owns `pgbouncer.get_auth`, but the migration that
*creates* it is `20250417190610` — a month later. On a fresh database the March one runs first, so `00-pre-init`
creates a stub for it.

## Updating

`upstream.env` pins the Supabase refs; the `ARG`s in the `Dockerfile` pin the Spilo base, pg_net and curl. Renovate
tracks all five.

A Renovate PR that bumps a Supabase ref does not itself update the vendored SQL — so CI re-runs
`scripts/sync-upstream.sh --check` and fails the PR until it is regenerated:

```bash
./scripts/sync-upstream.sh
```

That way the migration diff an upgrade actually implies shows up in the PR, which is the part worth reviewing.

> [!IMPORTANT]
> **The bootstrap runs once, at initdb, and never again.** Patroni invokes `post_init` only when it
> initialises a brand new cluster, and the script additionally no-ops if the `auth` schema already exists.
>
> So rolling an existing cluster onto a newer image gives it new binaries, new extension `.so` files and new
> SQL on disk — and leaves its schema exactly where it was. Nothing updates installed extension versions
> either; Postgres never runs `ALTER EXTENSION … UPDATE` on its own.
>
> Closing that gap is what `scripts/migrate.sh` is for. It is not automatic: you have to run it.

### Upgrading an existing database

After rolling the cluster onto a newer image, run the migration Job (`examples/job-migrate.yaml`), or invoke
it directly:

```bash
kubectl exec -n supabase "$LEADER" -c postgres -- \
  env CONN=dbname=postgres /scripts/migrate.sh --dry-run
```

It works out which files are new by comparing what is in the image against what the database records in
`supabase_spilo.applied_migrations`, applies only those, and then brings extension versions up.

| flag | |
| --- | --- |
| `--dry-run` | list the delta and the extension updates, change nothing |
| `--baseline` | adopt a database bootstrapped by an image older than migration tracking — records what is in the image as applied **without running it** |
| `--skip-extensions` | skip `ALTER EXTENSION … UPDATE` |

**Failure semantics.** Each migration runs in its own transaction with its tracking row written *inside* that
transaction, so a migration either fully applies and is recorded, or does neither — never half. On failure the
run stops immediately and exits non-zero; migrations already applied stay applied, and a re-run resumes from
the failure. This is deliberately not all-or-nothing: a resumable partial upgrade beats an unresumable
rollback, and statements like `CREATE DATABASE` cannot be transactional anyway.

It also refuses to run against a replica, takes an advisory lock so two Jobs cannot race, and warns when a
file recorded as applied has changed upstream or vanished from the image.

> [!TIP]
> Roll onto an **immutable** reference, not `:18`. The floating tags are mutable, and Kubernetes defaults to
> `imagePullPolicy: IfNotPresent` for a tag it already has — so a node that has cached `:18` keeps running the
> old image while you believe you have upgraded, and `migrate.sh` then finds nothing to do because the new
> migrations never arrived on disk. Use `18-<spilo>-<supabase-ref>`, or pin the digest outright:
>
> ```yaml
> dockerImage: docker.io/fzoc/supabase-spilo@sha256:<digest>
> ```

**Adopting an existing database.** A cluster bootstrapped before this mechanism existed has no tracking table.
`migrate.sh` refuses to guess and tells you to re-run with `--baseline`, which records the image's files as
applied without executing them. That is only correct if the database was bootstrapped from the *same* image
ref or newer — so baseline first, **then** update the image.

## Building and testing locally

```bash
docker build -t supabase-spilo:local .
./scripts/smoke-test.sh supabase-spilo:local
```

The smoke test starts a throwaway Postgres inside the image and asserts the preload set loads, every extension
creates, `pg_net` completes a real HTTP request, and `authenticator` can still connect with
`session_preload_libraries = supautils, safeupdate` — the setting that makes PostgREST fail outright on a stock Spilo.

```bash
./scripts/bootstrap-test.sh supabase-spilo:local
```

The bootstrap test then runs `supabase_post_init.sh` for real — same arguments Patroni passes, same mounted-secret
directory, every phase — and asserts what came out: each service role exists and has a password, the schemas and
`auth.users` are there, `_supabase` was created, `authenticator` carries the `supautils` preload, `anon` cannot read
`pg_stat_statements`, and every vendored `.sql` file actually executed.

That last count is the one that matters when upstream adds a migration: it fails if a file is vendored but never
run.

```bash
./scripts/upgrade-test.sh supabase-spilo:local
```

The upgrade test bootstraps a database, simulates a newer image arriving with extra migrations, and checks
`migrate.sh` applies exactly those and records them; that a second run is a no-op; and that a deliberately
broken migration fails the run *without* being recorded, so a re-run retries it.

All three run in CI, on both architectures.

## Does it pick up new upstream migrations?

Yes, for a **new** cluster — `sync-upstream.sh` lists the migration directory from the API rather than hardcoding
names, so a new file is vendored automatically, and `run_phase` executes everything it finds. Ordering is by
`LC_ALL=C sort` rather than glob expansion, so it does not depend on the container's locale; new timestamped
migrations land after the existing ones and before the `zz-` prefixed self-host extras, which is the order the
upstream compose applies them in.

For an **existing** cluster, only when you run `scripts/migrate.sh` — the bootstrap itself never runs again.
See [Upgrading an existing database](#upgrading-an-existing-database).

## About pg_net

`pg_net >= 0.20` calls `curl_easy_header()`, added in libcurl 7.83. Spilo is built on Ubuntu jammy, which ships
7.81 — which is exactly why Pigsty's jammy `pg_net` package is frozen at 0.9.2 while its noble one tracks upstream.

So this image builds a current libcurl and links it **statically** into `pg_net.so`, leaving the runtime image's own
`libcurl4` untouched for everything else. The trade is that this libcurl gets no distro security updates, so the
version is Renovate-tracked and the image rebuilds weekly.

## Caveats

- **`pgsodium_getkey` is development grade.** It returns a fresh random key each start, so anything pgsodium encrypts
  does not survive a restart. Mount a real key over
  `/usr/share/postgresql/18/extension/pgsodium_getkey` before storing anything you need to read back.
- **Realtime needs `wal_level=logical`** and will hold a replication slot. Spilo's `max_slot_wal_keep_size` defaults
  to `-1`, so a stalled slot will fill the volume with no ceiling. The example sets a bound.
- The Pigsty package versions are not pinned; they float with the repository.

## Licence

Apache-2.0. The SQL under `migrations/10-init-scripts` and `migrations/20-migrations` is vendored from
[supabase/postgres](https://github.com/supabase/postgres) and [supabase/supabase](https://github.com/supabase/supabase),
both Apache-2.0; see `NOTICE`.
