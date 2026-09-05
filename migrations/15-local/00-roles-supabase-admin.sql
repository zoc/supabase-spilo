-- Upstream's roles.sql sets a password for authenticator, pgbouncer,
-- supabase_auth_admin, supabase_functions_admin and supabase_storage_admin --
-- but not supabase_admin, because in Supabase's own image supabase_admin IS
-- the initdb superuser and already has POSTGRES_PASSWORD. On Spilo the initdb
-- superuser is postgres, so supabase_admin is left with no password at all,
-- and both realtime and postgres-meta connect as it.
\set pgpass `echo "$POSTGRES_PASSWORD"`
ALTER USER supabase_admin WITH PASSWORD :'pgpass';
