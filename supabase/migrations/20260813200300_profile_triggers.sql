-- The three triggers that keep public.profiles honest.
--
--   1. private.handle_new_user()             a profile appears when an account does
--   2. private.sync_institution_from_email() the badge is derived, never declared
--   3. private.protect_profile_columns()     system-owned columns cannot be written
--
-- Together these are the reason an institutional badge means anything. Item 2 is the only
-- code path in the entire project that can set an institution, and it reads the address
-- out of auth.users rather than accepting one. There is no request shape — none — that
-- carries an affiliation from a browser into this table.

-- ════════════════════════════════════════════════════════════════════════════════════
-- 1. A profile for every account
-- ════════════════════════════════════════════════════════════════════════════════════
-- SECURITY DEFINER because the caller is the auth service, connecting as
-- supabase_auth_admin, which has no privileges on public.profiles and should not be
-- given any.
--
-- The default display name is deliberately NOT derived from the email address. The local
-- part of an address is often a full name, and this site must work for someone whose
-- reason for being here is that they cannot afford to be identified. A signup form may
-- supply display_name in the user metadata; otherwise the fallback is derived from the
-- account id, which is already public as profiles.id and so reveals nothing new.

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
begin
  v_display_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');

  if v_display_name is null then
    v_display_name := 'Member ' || left(replace(new.id::text, '-', ''), 8);
  end if;

  insert into public.profiles (id, display_name)
  values (new.id, left(v_display_name, 80))
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function private.handle_new_user() is
  'Creates the public.profiles row for a new account. Never derives a display name from '
  'the email address.';

revoke all on function private.handle_new_user() from public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function private.handle_new_user();

-- ════════════════════════════════════════════════════════════════════════════════════
-- 2. The badge, derived from a confirmed address
-- ════════════════════════════════════════════════════════════════════════════════════
-- Fires when an address becomes confirmed, and again if a confirmed address is later
-- changed. The second case is not optional: without it, someone could confirm at a
-- university, collect the badge, then move the account to a personal address and keep an
-- institution they no longer have any claim to. Re-deriving on every change means the
-- badge always reflects the address currently on the account.
--
-- A match that fails clears the institution columns rather than leaving them. Failing
-- open here would be the whole vulnerability.
--
-- The name and country are copied rather than joined. See the profiles migration: a badge
-- is an attestation about a date, not a live lookup.

create or replace function private.sync_institution_from_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_domain  text;
  v_ror_id  text;
  v_name    text;
  v_country text;
begin
  -- split_part returns '' rather than null for an address with no '@', which
  -- match_institution rejects.
  v_domain := lower(btrim(split_part(coalesce(new.email, ''), '@', 2)));

  v_ror_id := private.match_institution(v_domain);

  if v_ror_id is not null then
    select i.name, i.country_name
      into v_name, v_country
      from private.ror_institutions i
     where i.ror_id = v_ror_id;
  end if;

  -- If the ROR row vanished between the match and this read, treat it as no match. The
  -- all-or-nothing constraint on profiles would reject a partial badge anyway; better to
  -- decide that here than to fail the user's confirmation.
  if v_ror_id is null or v_name is null or v_country is null then
    update public.profiles p
       set institution_ror_id      = null,
           institution_name        = null,
           institution_country     = null,
           institution_verified_at = null,
           updated_at              = now()
     where p.id = new.id
       and p.institution_ror_id is not null;
  else
    update public.profiles p
       set institution_ror_id      = v_ror_id,
           institution_name        = v_name,
           institution_country     = v_country,
           institution_verified_at = now(),
           updated_at              = now()
     where p.id = new.id;
  end if;

  return new;
end;
$$;

comment on function private.sync_institution_from_email() is
  'Derives the institutional badge from the confirmed address on auth.users. The only '
  'code path permitted to write the institution columns.';

revoke all on function private.sync_institution_from_email() from public;

create trigger on_auth_user_email_confirmed
  after update of email, email_confirmed_at on auth.users
  for each row
  when (
    -- first confirmation
    (old.email_confirmed_at is null and new.email_confirmed_at is not null)
    -- or a confirmed address that has since changed
    or (new.email is distinct from old.email and new.email_confirmed_at is not null)
  )
  execute function private.sync_institution_from_email();

-- ════════════════════════════════════════════════════════════════════════════════════
-- 3. System-owned columns are reverted, not merely ungranted
-- ════════════════════════════════════════════════════════════════════════════════════
-- The column-level UPDATE grants in the profiles migration already reject an attempt to
-- write these. This trigger is the second lock, because grants are one ALTER away from
-- being widened by someone adding a feature in a hurry, and the failure would be silent
-- until somebody noticed a stranger wearing a Bonn badge.
--
-- SECURITY INVOKER — and this is the subtle part
-- ---------------------------------------------
-- This function must NOT be SECURITY DEFINER. Inside a DEFINER function `current_user`
-- is the function's owner, so the check below would see the owner on every call,
-- including calls made by a browser, conclude that every caller was trusted, and revert
-- nothing at all. The guard would read as though it worked and would protect nothing.
--
-- As an INVOKER function, `current_user` is whoever is actually running the statement:
-- `authenticated` for a browser, and the table owner when one of our own DEFINER triggers
-- above performs the update. That is exactly the distinction this needs to make.
--
-- The trusted set is computed from the table's actual owner rather than a hardcoded role
-- name, so it stays correct if migrations are ever applied as a different role, and it
-- fails safe: a role nobody anticipated is guarded rather than trusted.

create or replace function private.protect_profile_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
  v_is_admin   boolean;
begin
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.profiles'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- An admin acting through the browser may moderate: set a role, ban an account. They
  -- still cannot invent an institution — see below.
  v_is_admin := exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and p.role = 'admin'
       and not p.is_banned
  );

  -- Institution columns are reverted for everybody, admins included. They are derived
  -- from a confirmed address by trigger 2 and there is no legitimate reason for a human
  -- to set them by hand; leaving an admin path open would make "verified" mean "verified,
  -- or an admin said so".
  new.institution_ror_id      := old.institution_ror_id;
  new.institution_name        := old.institution_name;
  new.institution_country     := old.institution_country;
  new.institution_verified_at := old.institution_verified_at;
  new.orcid_verified          := old.orcid_verified;

  -- Immutable for everyone. Reassigning an id would move a profile onto another account.
  new.id         := old.id;
  new.created_at := old.created_at;

  if not v_is_admin then
    new.role      := old.role;
    new.is_banned := old.is_banned;
  end if;

  return new;
end;
$$;

comment on function private.protect_profile_columns() is
  'Reverts writes to system-owned columns on public.profiles. Deliberately SECURITY '
  'INVOKER: as DEFINER, current_user would always be the owner and the guard would never '
  'fire.';

-- No EXECUTE grant to anon or authenticated, and none is needed. Postgres checks EXECUTE
-- on a trigger function when the trigger is *created*, not each time it fires, so this
-- runs for a browser session that cannot even resolve the name. Nothing at all is granted
-- on the private schema; the pgTAP suite asserts that and also proves the guard still
-- fires for an authenticated caller.
revoke all on function private.protect_profile_columns() from public;

create trigger profiles_protect_system_columns
  before update on public.profiles
  for each row
  execute function private.protect_profile_columns();
