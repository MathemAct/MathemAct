-- What the browser can and cannot reach.
--
-- These assertions are about the shape of the API surface rather than about behaviour.
-- They exist because the two ways this system fails are both invisible from the client:
-- a table that was never granted looks exactly like a table whose policy returns nothing,
-- and an email address leaking through a view looks exactly like a working feature.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(29);

-- The private schema is not reachable at all ------------------------------------------

select ok(
  not has_schema_privilege('anon', 'private', 'USAGE'),
  'anon has no USAGE on the private schema'
);

select ok(
  not has_schema_privilege('authenticated', 'private', 'USAGE'),
  'authenticated has no USAGE on the private schema'
);

select is_empty(
  $$ select grantee || ' ' || privilege_type || ' on ' || table_name
       from information_schema.role_table_grants
      where table_schema = 'private'
        and grantee in ('anon', 'authenticated') $$,
  'no table in the private schema is granted to anon or authenticated'
);

set local role anon;
select throws_ok(
  $$ select count(*) from private.ror_domains $$,
  '42501'::text, null::text,
  'anon cannot read private.ror_domains'
);
select throws_ok(
  $$ select count(*) from private.blocked_domains $$,
  '42501'::text, null::text,
  'anon cannot read private.blocked_domains'
);
select throws_ok(
  $$ select count(*) from private.manual_domains $$,
  '42501'::text, null::text,
  'anon cannot read private.manual_domains'
);
select throws_ok(
  $$ select private.match_institution('ox.ac.uk') $$,
  '42501'::text, null::text,
  'anon cannot call match_institution directly'
);
reset role;

set local role authenticated;
select throws_ok(
  $$ select count(*) from private.ror_institutions $$,
  '42501'::text, null::text,
  'authenticated cannot read private.ror_institutions'
);
reset role;

-- No route reaches an email address ---------------------------------------------------

select is_empty(
  $$ select table_name || '.' || column_name
       from information_schema.columns
      where table_schema = 'public'
        and column_name ilike '%email%' $$,
  'no column in the exposed schema is named like an email address'
);

select is_empty(
  $$ select viewname
       from pg_views
      where schemaname = 'public'
        and definition ilike '%auth.users%' $$,
  'no view in the exposed schema is defined over auth.users'
);

select is_empty(
  $$ select matviewname
       from pg_matviews
      where schemaname = 'public'
        and definition ilike '%auth.users%' $$,
  'no materialized view in the exposed schema is defined over auth.users'
);

-- Any function the browser could call that mentions an email at all. There should be
-- none: our own functions live in the private schema, which has no USAGE grant.
select is_empty(
  $$ select p.proname
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prokind = 'f'
        and pg_get_functiondef(p.oid) ilike '%email%' $$,
  'no function in the exposed schema mentions an email address'
);

select is_empty(
  $$ select privilege_type
       from information_schema.role_table_grants
      where table_schema = 'auth'
        and table_name = 'users'
        and grantee in ('anon', 'authenticated') $$,
  'neither anon nor authenticated holds any privilege on auth.users'
);

-- Row level security is on everywhere -------------------------------------------------

select ok(
  (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass),
  'row level security is enabled on public.profiles'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'private.ror_institutions'::regclass),
  'row level security is enabled on private.ror_institutions'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'private.ror_domains'::regclass),
  'row level security is enabled on private.ror_domains'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'private.blocked_domains'::regclass),
  'row level security is enabled on private.blocked_domains'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'private.manual_domains'::regclass),
  'row level security is enabled on private.manual_domains'
);

-- profiles is granted exactly as intended ---------------------------------------------

select ok(
  has_table_privilege('anon', 'public.profiles', 'SELECT'),
  'anon may select profiles -- they are public by design'
);
select ok(
  has_table_privilege('authenticated', 'public.profiles', 'SELECT'),
  'authenticated may select profiles'
);
select ok(
  not has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
  'authenticated cannot insert a profile; rows come from the auth.users trigger'
);
select ok(
  not has_table_privilege('authenticated', 'public.profiles', 'DELETE'),
  'authenticated cannot delete a profile; removal is by cascade from auth.users'
);

-- The column-level split. This is the first of the two locks on system-owned columns.
select ok(
  has_column_privilege('authenticated', 'public.profiles', 'display_name', 'UPDATE'),
  'authenticated may update their display name'
);
select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE'),
  'authenticated has no column grant on role'
);
select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'is_banned', 'UPDATE'),
  'authenticated has no column grant on is_banned'
);
select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'institution_name', 'UPDATE'),
  'authenticated has no column grant on institution_name'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.settings'::regclass),
  'row level security is enabled on private.settings'
);

-- The two systemic guards -------------------------------------------------------------
-- Written against the catalogue rather than against a list of table names, so they cover
-- tables that do not exist yet. Row level security defaults to permissive when someone
-- forgets to enable it, and that omission is invisible from the client: the table simply
-- answers every question it is asked.

select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'r'
        and not c.relrowsecurity $$,
  'every table in the exposed schema has row level security enabled'
);

-- A view has no row level security of its own and runs with its creator's privileges
-- unless told otherwise, so an ordinary view over a user-content table hands pending and
-- hidden rows to anonymous callers while looking entirely correct in review.
-- Cast rather than string-compare. Postgres stores a boolean reloption exactly as it was
-- written, so `with (security_invoker = on)` reads back as 'on' and a test looking for
-- 'true' reports a correctly protected view as a leak. That is the worst way for a
-- security assertion to be wrong: it cries wolf until somebody relaxes it.
select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'v'
        and not coalesce(
              (select o.option_value
                 from pg_options_to_table(c.reloptions) o
                where o.option_name = 'security_invoker')::boolean,
              false) $$,
  'every view in the exposed schema is security_invoker'
);

select * from finish();

rollback;
