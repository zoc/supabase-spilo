-- Supabase's own image creates supabase_admin in its docker-entrypoint, before
-- any migration runs; Spilo has no equivalent, and initial-schema.sql opens
-- with "alter user supabase_admin with superuser", which fails on a role that
-- does not exist yet. Create it unprivileged here and let that ALTER promote it.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin WITH LOGIN;
  END IF;
END $$;
