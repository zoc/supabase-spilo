-- The pgbouncer role, its schema and get_auth() are created by Supabase's
-- platform provisioning, not by the open-source migration set -- so on a
-- Spilo bootstrap they are simply absent, and three migrations assume them:
--   99-roles.sql              ALTER USER pgbouncer WITH PASSWORD
--   20250312095419            ALTER FUNCTION pgbouncer.get_auth OWNER TO
--   20251121132723            ALTER FUNCTION ... SET search_path
-- Note the ordering trap: 20250312095419 (March) re-owns get_auth, but the
-- migration that defines it is 20250417190610 (April). On a fresh database
-- the March one runs first, so the function has to exist up front. The April
-- migration then CREATE OR REPLACEs this stub.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') THEN
    CREATE ROLE pgbouncer WITH LOGIN;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
  RETURNS TABLE (username text, password text)
  LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
    SELECT rolname::text,
           CASE WHEN rolvaliduntil < now() THEN NULL ELSE rolpassword::text END
    FROM pg_authid WHERE rolname = $1 AND rolcanlogin;
END;
$$;
