-- Spilo creates its monitoring views in the PUBLIC schema and grants SELECT on
-- them to PUBLIC (relacl "=r/postgres"). On a plain Spilo that is harmless.
-- Under Supabase, "public" is the schema PostgREST exposes, and anon inherits
-- every PUBLIC grant -- so these views become readable over the internet with
-- nothing but the anon key.
--
-- Postgres masks the statement text itself for non-superusers, so what leaks is
-- call counts and timings rather than queries, but there is no reason for it to
-- be reachable anonymously at all.
--
-- Note this MUST be a revoke from PUBLIC, not from anon: anon holds no direct
-- grant, so "revoke ... from anon" is silently a no-op.
--
-- Spilo's own monitoring (admin, robot_zmon) does depend on these, so they get
-- an explicit grant to replace the blanket one. Runs after Spilo's post_init,
-- and before any user table exists.
DO $$
DECLARE
  v_rel   text;
  v_role  text;
BEGIN
  FOREACH v_rel IN ARRAY ARRAY[
    'public.pg_stat_statements',
    'public.pg_stat_statements_info',
    'public.pg_stat_kcache',
    'public.pg_stat_kcache_detail'
  ] LOOP
    -- Guarded: a future Spilo may not ship all of these.
    IF to_regclass(v_rel) IS NULL THEN
      RAISE NOTICE 'skipping %, not present', v_rel;
      CONTINUE;
    END IF;

    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC', v_rel);

    FOREACH v_role IN ARRAY ARRAY['admin', 'robot_zmon'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
        EXECUTE format('GRANT SELECT ON %s TO %I', v_rel, v_role);
      END IF;
    END LOOP;

    RAISE NOTICE 'revoked PUBLIC select on %', v_rel;
  END LOOP;
END $$;
