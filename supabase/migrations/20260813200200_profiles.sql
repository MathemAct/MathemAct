-- public.profiles — the only user-facing record of a person on this site.
--
-- THERE IS NO EMAIL COLUMN, AND THERE NEVER WILL BE.
--
-- The address a person signs up with stays in auth.users, which the browser cannot
-- reach. It is used for exactly two things: signing in, and deriving the institutional
-- badge server-side. It is never displayed, never returned by the API, never in the
-- nightly export, and never shown to a moderator. Adding an email column here, or a view
-- or function that returns one, would defeat all of that in a single line. Do not.
--
-- Pseudonymity is a first-class requirement rather than a courtesy. Admitting to heavy
-- reliance on AI tools still carries professional risk, and an account that can only be
-- given under a real name is an account that will not be given.
--
-- Two groups of columns behave very differently:
--
--   Owned by the user   display_name, is_pseudonym, bio, orcid
--   Owned by the system institution_*, orcid_verified, role, is_banned
--
-- The second group is enforced twice over: column-level UPDATE grants below, and a
-- BEFORE UPDATE trigger in the next migration that reverts any change to them. Either
-- alone would be enough on a good day. Badges are only worth something if they are worth
-- something on a bad day.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,

  -- ── The user's own ────────────────────────────────────────────────────────────────
  display_name text not null,
  is_pseudonym boolean not null default false,
  bio          text,
  orcid        text,

  -- ── The system's ──────────────────────────────────────────────────────────────────
  -- An institution is a point-in-time attestation, not a live lookup: name and country
  -- are copied here when the badge is issued and are never refreshed from ROR. That is
  -- deliberate. A badge claims "this address was confirmed at this institution on this
  -- date", and rewriting history because ROR later renamed a record would make the claim
  -- untrue. It is also why there is no foreign key to private.ror_institutions — CI
  -- reloads that table wholesale, and a routine data refresh must not be able to fail or
  -- to mutate anyone's profile.
  orcid_verified          boolean not null default false,
  institution_ror_id      text,
  institution_name        text,
  institution_country     text,
  institution_verified_at timestamptz,

  role      text not null default 'member',
  is_banned boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- ── Constraints ───────────────────────────────────────────────────────────────────
  -- Mirrored in src/lib/ for the form. Client validation is convenience; this is truth.
  constraint profiles_display_name_length
    check (length(btrim(display_name)) between 1 and 80),

  constraint profiles_bio_length
    check (bio is null or length(bio) <= 1000),

  constraint profiles_role_valid
    check (role in ('member', 'moderator', 'admin')),

  -- ORCID iDs are 16 digits in four groups; the final character may be X as a checksum.
  constraint profiles_orcid_format
    check (orcid is null or orcid ~ '^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$'),

  -- An unverified iD may be present; a verified flag without one may not.
  constraint profiles_orcid_verified_needs_orcid
    check (not orcid_verified or orcid is not null),

  -- The institution snapshot is all four columns or none. A half-written badge would
  -- render as an institution with no verification date, which is precisely the claim
  -- this project must never make.
  constraint profiles_institution_all_or_nothing check (
    (institution_ror_id is null
      and institution_name is null
      and institution_country is null
      and institution_verified_at is null)
    or
    (institution_ror_id is not null
      and institution_name is not null
      and institution_country is not null
      and institution_verified_at is not null)
  )
);

comment on table public.profiles is
  'Public profile for an account. Contains no email address by design; see the header of '
  'the migration that created it.';
comment on column public.profiles.institution_verified_at is
  'When the email domain was matched. Always displayed alongside the institution, because '
  'a badge attests to a check on a date and not to current employment.';
comment on column public.profiles.is_pseudonym is
  'Set by the user. A pseudonym is permitted at every verification tier, including with '
  'an institutional badge.';
comment on column public.profiles.role is
  'System-owned. Changed only by an admin or by a direct database session.';

create index profiles_institution_ror_id_idx
  on public.profiles (institution_ror_id)
  where institution_ror_id is not null;

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.profiles enable row level security;

-- Profiles are public. Everything in this table is intended to be displayed next to the
-- author's contributions, which is why nothing sensitive is allowed to live here.
create policy profiles_select_public
  on public.profiles
  for select
  to anon, authenticated
  using (true);

-- A user may update their own row and no other. The protected columns are handled
-- separately; this policy governs which *row* is reachable, not which columns.
--
-- auth.uid() is wrapped in a scalar subquery so the planner evaluates it once per
-- statement rather than once per row.
create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- No INSERT policy and no DELETE policy, on purpose.
--
-- Rows are created by the trigger that fires when auth.users gains a row, and removed by
-- the cascade when that row goes. A user who could insert directly could create a profile
-- for an account id that is not theirs; a user who could delete could drop their profile
-- while keeping the account, detaching their content from moderation. Both paths are
-- simply absent rather than policed.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- New tables are not auto-exposed in this project, so without these the table has no
-- endpoint at all. Grants decide whether the endpoint exists; policies decide which rows
-- it returns. Both are needed, and a missing grant looks identical to a missing policy
-- from the client — check grants first.

grant select on public.profiles to anon, authenticated;

-- UPDATE is granted per column, not on the table. This is the first of the two locks on
-- the system-owned columns: an attempt to set `role` is rejected by Postgres before any
-- trigger runs, with a permission error rather than a silent no-op.
--
-- Deliberately absent from this list: orcid_verified, institution_ror_id,
-- institution_name, institution_country, institution_verified_at, role, is_banned, id,
-- created_at, updated_at.
grant update (display_name, is_pseudonym, bio, orcid) on public.profiles to authenticated;

-- No INSERT or DELETE grant to any application role, matching the absent policies.
