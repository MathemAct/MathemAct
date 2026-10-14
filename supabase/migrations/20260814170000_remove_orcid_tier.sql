-- Removes the ORCID verification tier.
--
-- Two tiers remain: Registered, and Institutional. Nothing user-facing mentions ORCID.
--
-- This is a scope decision, not a technical one. The OAuth link built earlier in the day
-- worked -- 14 pgTAP assertions covered linking, unlinking, non-ORCID identities, a
-- malformed subject, and an issuer fallback -- but it required registering an ORCID client
-- and configuring a custom provider in the Supabase dashboard before it could do anything,
-- and it added a fifth data processor to the privacy notice for a badge nobody had asked
-- for yet. docs/decisions.md records what it would take to revive it.
--
-- Migrations are append-only, so this drops rather than editing what created these
-- objects. The two ORCID migrations remain in the history as the record of what was there.
--
-- Safe to drop the columns outright: there are no accounts, so there is no data to lose.

-- The trigger and its function go first: both read public.profiles.orcid, and dropping the
-- columns underneath a live trigger would leave the next identity write failing.
drop trigger if exists on_auth_identity_changed on auth.identities;
drop function if exists private.sync_orcid_identity();

-- private.settings stays. It was introduced for the ORCID provider identifier, but it is
-- named in CLAUDE.md as expected private-schema infrastructure independently of ORCID, and
-- an empty table with row level security on and no grants costs nothing. Only the rows go.
delete from private.settings where key in ('orcid_provider', 'orcid_issuer');

-- The guard, without the two columns. Unchanged in every other respect, including why it
-- is SECURITY INVOKER rather than DEFINER: inside a DEFINER function current_user is the
-- owner, so the check below would see a trusted caller on every request and revert
-- nothing. See the migration that created it.
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

  v_is_admin := exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and p.role = 'admin'
       and not p.is_banned
  );

  -- Derived from a confirmed address, and reverted for everyone including admins. An admin
  -- path here would make "verified" mean "verified, or somebody with a moderator account
  -- said so".
  new.institution_ror_id      := old.institution_ror_id;
  new.institution_name        := old.institution_name;
  new.institution_country     := old.institution_country;
  new.institution_verified_at := old.institution_verified_at;
  new.institution_source      := old.institution_source;

  new.id         := old.id;
  new.created_at := old.created_at;

  if not v_is_admin then
    new.role      := old.role;
    new.is_banned := old.is_banned;
  end if;

  return new;
end;
$$;

revoke all on function private.protect_profile_columns() from public;

-- Constraints named explicitly rather than relying on the cascade from DROP COLUMN, so
-- that a rename upstream fails loudly here instead of leaving one behind.
alter table public.profiles drop constraint if exists profiles_orcid_verified_iff_present;
alter table public.profiles drop constraint if exists profiles_orcid_verified_needs_orcid;
alter table public.profiles drop constraint if exists profiles_orcid_format;

alter table public.profiles drop column if exists orcid_verified;
alter table public.profiles drop column if exists orcid;
