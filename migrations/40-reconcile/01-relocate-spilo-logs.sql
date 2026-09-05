-- Spilo's log plumbing lives in public: postgres_log (an inheritance parent),
-- one file_fdw foreign table per log file beneath it, and a
-- failed_authentication view over each -- 17 objects. On a stock Spilo that is
-- invisible. Under Supabase, public is the schema PostgREST exposes and
-- Studio's table editor lists, so Spilo's internals appear as if they were the
-- user's own tables.
--
-- Moving them is safe. Nothing in Spilo reads them back: post_init.sh creates
-- them, and the only other script that mentions them (maybe_pg_upgrade.py)
-- tails the CSV files on disk rather than querying the tables.
--
-- But it does not STAY done, which is why this lives in the reconcile phase.
-- Spilo re-runs post_init.sh on every promotion to primary, and its
-- CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE VIEW happily recreate the
-- objects in public once they are no longer there. This file therefore has to
-- cope with a public copy reappearing next to the relocated one, and on every
-- run leave exactly one set, in spilo.
--
-- Names are matched by pattern rather than hardcoded: Spilo emits
-- postgres_log_<d> normally but postgres_log_<d>_<hh> under LOG_SHIP_HOURLY.
DO $$
DECLARE
  r       record;
  moved   int := 0;
  dropped int := 0;
BEGIN
  IF to_regclass('public.postgres_log') IS NULL THEN
    RETURN;                               -- nothing in public; already reconciled
  END IF;

  CREATE SCHEMA IF NOT EXISTS spilo;
  COMMENT ON SCHEMA spilo IS
    'Spilo''s own log plumbing, kept out of public so it is not mistaken for user data.';

  EXECUTE 'REVOKE ALL ON SCHEMA spilo FROM PUBLIC';
  EXECUTE 'GRANT USAGE ON SCHEMA spilo TO postgres';
  -- Object grants survive a SET SCHEMA, but the holders need USAGE to reach them.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin')      THEN EXECUTE 'GRANT USAGE ON SCHEMA spilo TO admin';      END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'robot_zmon') THEN EXECUTE 'GRANT USAGE ON SCHEMA spilo TO robot_zmon'; END IF;

  -- Views, then the inheriting foreign tables, then the parent. SET SCHEMA does
  -- not care (dependencies are by OID), but DROP does, and this ordering serves
  -- both.
  FOR r IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace
      AND c.relkind IN ('r','v','f')
      AND (c.relname ~ '^failed_authentication(_[0-9]+)*$'
        OR c.relname ~ '^postgres_log(_[0-9]+)*$')
    ORDER BY CASE c.relkind WHEN 'v' THEN 1 WHEN 'f' THEN 2 ELSE 3 END,
             length(c.relname) DESC
  LOOP
    IF to_regclass('spilo.' || quote_ident(r.relname)) IS NOT NULL THEN
      -- Already relocated on an earlier run and recreated in public by Spilo
      -- since. The public one is a fresh empty duplicate over the same files;
      -- the spilo one is the one everything else now points at.
      EXECUTE format('DROP %s IF EXISTS public.%I CASCADE',
                     CASE r.relkind WHEN 'v' THEN 'VIEW'
                                    WHEN 'f' THEN 'FOREIGN TABLE'
                                    ELSE 'TABLE' END,
                     r.relname);
      dropped := dropped + 1;
    ELSE
      EXECUTE format('ALTER %s public.%I SET SCHEMA spilo',
                     CASE r.relkind WHEN 'v' THEN 'VIEW'
                                    WHEN 'f' THEN 'FOREIGN TABLE'
                                    ELSE 'TABLE' END,
                     r.relname);
      moved := moved + 1;
    END IF;
  END LOOP;

  IF moved > 0 OR dropped > 0 THEN
    RAISE NOTICE 'spilo log objects: % moved to spilo, % duplicate(s) dropped from public', moved, dropped;
  END IF;
END $$;
