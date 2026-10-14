-- The ORCID tier becomes a verified link instead of a self-declared string.
--
-- What was wrong
-- --------------
-- profiles.orcid was writable by its owner and profiles.orcid_verified was merely a flag
-- nothing ever set. Resolving a submitted iD against ORCID's public API proves that the
-- iD *exists*; it proves nothing at all about who typed it. Anyone could have pasted a
-- well-known mathematician's iD and worn a badge reading "ORCID-linked", which contradicts
-- the one rule this project cannot bend: a badge states only what was verified.
--
-- What replaces it
-- ----------------
-- ORCID is a conformant OpenID Connect provider. Its id_token carries the ORCID iD in the
-- `sub` claim -- literally "sub": "0000-0002-5062-2209" -- and the `openid` scope is all
-- that is needed to get it. Supabase performs the code exchange with the client secret,
-- which lives in its dashboard alongside the Turnstile and Brevo secrets and never comes
-- near this repository. The resulting identity lands in auth.identities.
--
-- So the iD is now read out of a completed OAuth flow by the trigger below, and there is
-- no request shape that lets anyone type one. profiles.orcid joins the institution columns
-- as system-owned: no column grant, and reverted by the guard.
--
-- Configuration this migration does NOT do
-- ----------------------------------------
-- Registering the ORCID client and adding the provider in the Supabase dashboard are
-- manual steps. See docs/orcid.md. Until they are done this trigger simply never fires,
-- which is the correct inert state rather than a broken one.

-- ── Settings ────────────────────────────────────────────────────────────────────────
-- The provider identifier is configuration, not code: it is chosen in the dashboard and
-- has to match here. Putting it in a table means correcting a mismatch is one UPDATE
-- rather than a migration.

create table private.settings (
  key        text primary key,
  value      text not null,
  note       text,
  updated_at timestamptz not null default now()
);

comment on table private.settings is
  'Server-side configuration that must agree with the Supabase dashboard. Never exposed.';

alter table private.settings enable row level security;

insert into private.settings (key, value, note) values
  ('orcid_provider', 'custom:orcid',
   'The identifier given to the ORCID provider in the Supabase dashboard. Custom providers '
   'are always prefixed custom:. Must match exactly what the client passes to linkIdentity.'),
  ('orcid_issuer', 'https://orcid.org',
   'ORCID''s OIDC issuer, checked as a second signal in case the provider identifier is '
   'ever renamed in the dashboard without this table being updated.');

-- ── The iD becomes system-owned ─────────────────────────────────────────────────────

revoke update (orcid) on public.profiles from authenticated;

comment on column public.profiles.orcid is
  'Read from a completed ORCID OAuth flow by private.sync_orcid_identity(). System-owned: '
  'there is no path by which a user can type one.';

-- The two columns are now one fact. An iD can only arrive verified, so an unverified one
-- must be unrepresentable rather than merely unusual.
alter table public.profiles drop constraint profiles_orcid_verified_needs_orcid;

alter table public.profiles
  add constraint profiles_orcid_verified_iff_present
  check (orcid_verified = (orcid is not null));

-- Any iD typed in before this change was never verified and cannot be trusted now. There
-- are no accounts yet, so this is a formality, but a migration that silently promoted
-- self-declared strings to verified would be exactly the bug being fixed.
update public.profiles
   set orcid = null, orcid_verified = false
 where orcid is not null and not orcid_verified;

-- ── Deriving the iD from the linked identity ────────────────────────────────────────
-- Recomputed from the whole identity set rather than from the row that changed, so insert,
-- update and delete all take one path and an account with several identities cannot end up
-- half-synchronised.

create or replace function private.sync_orcid_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid;
  v_provider text;
  v_issuer   text;
  v_orcid    text;
begin
  if tg_op = 'DELETE' then
    v_user := old.user_id;
  else
    v_user := new.user_id;
  end if;

  if v_user is null then
    return null;
  end if;

  select s.value into v_provider from private.settings s where s.key = 'orcid_provider';
  select s.value into v_issuer   from private.settings s where s.key = 'orcid_issuer';

  -- Matched on the configured provider identifier or on ORCID's issuer, so a rename in
  -- the dashboard degrades to the other signal instead of silently unlinking everyone.
  --
  -- The shape of the subject is checked as well. ORCID's `sub` is the iD itself, so a
  -- value that is not an iD means this is not the provider we think it is, and inventing
  -- a badge from it would be worse than having none.
  select i.identity_data ->> 'sub'
    into v_orcid
    from auth.identities i
   where i.user_id = v_user
     and (i.provider = v_provider or i.identity_data ->> 'iss' = v_issuer)
     and i.identity_data ->> 'sub' ~ '^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$'
   order by i.created_at asc
   limit 1;

  update public.profiles p
     set orcid          = v_orcid,
         orcid_verified = (v_orcid is not null),
         updated_at     = now()
   where p.id = v_user
     and p.orcid is distinct from v_orcid;

  return null;
end;
$$;

comment on function private.sync_orcid_identity() is
  'Sets profiles.orcid from a linked ORCID OAuth identity. The only path by which an ORCID '
  'iD can reach a profile.';

revoke all on function private.sync_orcid_identity() from public;

create trigger on_auth_identity_changed
  after insert or update or delete on auth.identities
  for each row
  execute function private.sync_orcid_identity();

-- ── The guard gains one more column ─────────────────────────────────────────────────
-- Unchanged in every other respect, including why it is SECURITY INVOKER rather than
-- DEFINER; see the migration that created it.

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

  -- Derived from a confirmed address or a completed OAuth flow, and reverted for everyone
  -- including admins. An admin path here would make "verified" mean "verified, or somebody
  -- with a moderator account said so".
  new.institution_ror_id      := old.institution_ror_id;
  new.institution_name        := old.institution_name;
  new.institution_country     := old.institution_country;
  new.institution_verified_at := old.institution_verified_at;
  new.institution_source      := old.institution_source;
  new.orcid                   := old.orcid;
  new.orcid_verified          := old.orcid_verified;

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
