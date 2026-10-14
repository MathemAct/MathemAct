-- public.profiles.confirmed_at — so that row level security can ask "has this person
-- confirmed their email address?"
--
-- Why this column has to exist
-- ----------------------------
-- The practice policies in the next migrations require an *authenticated, confirmed,
-- non-banned* user. Authenticated and non-banned are already answerable: one is the role,
-- the other is a column on this table. Confirmed is not, and none of the obvious routes
-- work:
--
--   auth.users.email_confirmed_at   `authenticated` holds no privilege on auth.users, and
--                                   a policy is evaluated with the caller's privileges.
--   a private helper function       `authenticated` has no USAGE on the private schema, so
--                                   a policy calling one fails on EXECUTE.
--   the JWT's user_metadata         raw_user_meta_data is written by the browser through
--                                   updateUser({ data }). A policy trusting an
--                                   `email_verified` claim from there would let anyone
--                                   mark themselves confirmed. Not a hypothetical: it is
--                                   the first thing to try.
--
-- So the fact is copied to where a policy can reach it, by the same SECURITY DEFINER
-- trigger that already reads auth.users to derive the badge. The address itself stays
-- where it is. A timestamp saying an address was confirmed reveals nothing about what the
-- address was.
--
-- On the name
-- -----------
-- Not `email_confirmed_at`, deliberately. 002_exposure.test.sql asserts that no column in
-- the exposed schema is named like an email address — a blunt instrument aimed at exactly
-- the kind of well-meaning addition that ends with an address in the API. Naming this
-- column after the account rather than the address keeps that assertion doing its job
-- instead of needing an exception carved into it.

alter table public.profiles
  add column confirmed_at timestamptz;

comment on column public.profiles.confirmed_at is
  'When this account confirmed its email address. System-owned, derived from auth.users by '
  'trigger. Exists so that row level security can require a confirmed account without any '
  'policy needing to read auth.users. Never holds, implies, or reveals the address itself.';

-- Partial: policies ask "is this confirmed", never "when". The index serves the common
-- shape of the question rather than the column.
create index profiles_confirmed_idx
  on public.profiles (id)
  where confirmed_at is not null;

-- No UPDATE grant. Joining the institution columns as system-owned, and reverted by the
-- guard below for the same reason: a member who could set this could post before
-- confirming, which is the whole point of requiring confirmation.

-- ── Deriving it ─────────────────────────────────────────────────────────────────────
-- Two triggers already watch auth.users, and both need to know about this column.

-- 1. Signup. Normally leaves confirmed_at null, because this project requires email
--    confirmation and a new row therefore has email_confirmed_at null. It is read anyway
--    rather than hardcoded to null, so that turning on auto-confirmation in the dashboard
--    -- or an account created by an admin through the Management API -- produces a
--    correct profile rather than one that can never post.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name  text;
  v_is_pseudonym  boolean;
begin
  v_display_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');

  -- The default display name is deliberately NOT derived from the email address. The local
  -- part of an address is often a full name, and this site must work for someone whose
  -- reason for being here is that they cannot afford to be identified.
  if v_display_name is null then
    v_display_name := 'Member ' || left(replace(new.id::text, '-', ''), 8);
  end if;

  -- Compared as text rather than cast to boolean. A cast throws on anything that is not a
  -- recognised boolean literal, and the value arrives from a browser: a malformed one must
  -- mean "not a pseudonym", not "signup failed".
  v_is_pseudonym :=
    lower(coalesce(new.raw_user_meta_data ->> 'is_pseudonym', '')) in ('true', 't', '1', 'yes');

  insert into public.profiles (id, display_name, is_pseudonym, confirmed_at)
  values (new.id, left(v_display_name, 80), v_is_pseudonym, new.email_confirmed_at)
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function private.handle_new_user() is
  'Creates the public.profiles row for a new account, reading display_name and is_pseudonym '
  'from signup metadata. Never derives a display name from the email address, and never '
  'reads any other key out of raw_user_meta_data.';

revoke all on function private.handle_new_user() from public;

-- 2. Confirmation. The trigger that derives the badge already fires on exactly the events
--    that change confirmation state, so the timestamp is written in the same statement
--    that writes the institution. Keeping them together means there is no window in which
--    an account has a badge but is not yet allowed to post, or the reverse.
--
--    confirmed_at is set on the *first* confirmation and never cleared. Changing to an
--    unconfirmed address re-derives the badge -- possibly to nothing -- but does not
--    revoke the right to post, because the account has been confirmed once and Supabase's
--    "secure email change" requires both addresses to agree before the change lands.
create or replace function private.sync_institution_from_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_domain  text;
  v_match   private.institution_match;
  v_name    text;
  v_country text;
begin
  -- split_part returns '' rather than null for an address with no '@', which
  -- match_institution rejects.
  v_domain := lower(btrim(split_part(coalesce(new.email, ''), '@', 2)));

  v_match := private.match_institution(v_domain);

  if v_match.ror_id is not null then
    select i.name, i.country_name
      into v_name, v_country
      from private.ror_institutions i
     where i.ror_id = v_match.ror_id;
  end if;

  -- A match that cannot be resolved to a name and country is treated as no match. This is
  -- the path a manual entry takes when it points at a ROR record that has since gone, and
  -- it is deliberately fail-safe: no badge rather than a half-written one.
  if v_match.ror_id is null or v_name is null or v_country is null then
    update public.profiles p
       set institution_ror_id      = null,
           institution_name        = null,
           institution_country     = null,
           institution_verified_at = null,
           institution_source      = null,
           confirmed_at            = coalesce(p.confirmed_at, new.email_confirmed_at),
           updated_at              = now()
     where p.id = new.id
       and (p.institution_ror_id is not null or p.confirmed_at is null);
  else
    update public.profiles p
       set institution_ror_id      = v_match.ror_id,
           institution_name        = v_name,
           institution_country     = v_country,
           institution_verified_at = now(),
           institution_source      = v_match.source,
           confirmed_at            = coalesce(p.confirmed_at, new.email_confirmed_at),
           updated_at              = now()
     where p.id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_institution_from_email() from public;

-- ── The guard gains one column ──────────────────────────────────────────────────────
-- Everything else about this function is unchanged, including why it is SECURITY INVOKER
-- rather than DEFINER: inside a DEFINER function current_user is the owner, so the check
-- below would see a trusted caller on every request and revert nothing.

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

  -- Reverted for admins too, and for the same reason. This column is the gate on posting;
  -- an admin who could set it could wave an unconfirmed account through, which would make
  -- "confirmed" mean "confirmed, or somebody said so".
  new.confirmed_at := old.confirmed_at;

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

-- ── Backfill ────────────────────────────────────────────────────────────────────────
-- There are no accounts yet, so this is a formality. It is here because the alternative is
-- a column that is null for every account created before this migration and correct for
-- every account after it, which is the kind of split that is discovered months later by
-- someone who cannot post.
update public.profiles p
   set confirmed_at = u.email_confirmed_at
  from auth.users u
 where u.id = p.id
   and p.confirmed_at is null
   and u.email_confirmed_at is not null;
