-- public.practices — a first-hand account of using an AI tool in mathematical work.
--
-- This is the corpus. Everything else in the project exists to get rows into this table
-- and to make them trustworthy once they are here.
--
-- The field order below follows the content model in CLAUDE.md, because the schema is the
-- reporting standard: the ambition is that a journal could adopt this shape as a tool
-- disclosure template, and a template whose fields are in a different order from the form
-- and the export is three templates.
--
-- Two things are constrained harder than a general forum would constrain them, and both
-- are deliberate:
--
--   `verification` is NOT NULL and must be non-empty after trimming. There is no skip and
--   no "not applicable". An account without it records that something felt right, which is
--   not a finding. This single field is what separates a corpus a mathematician can use
--   from a pile of anecdotes, and it is enforced here rather than only in the form because
--   PostgREST is a public endpoint and our form is not the only way to reach it.
--
--   `third_party_material_confirmed` must be true, not merely present. Transcripts get
--   pasted with other people's unpublished work in them. The column records that a person
--   affirmed they had removed it, attached to the row it is about, which is the only place
--   that affirmation is worth anything.
--
-- Character caps mirror the form's. The database is the truth and the form is the
-- convenience; when a cap changes, it changes here first. src/lib/validation.ts will carry
-- the same numbers when the submission form is built.
--
-- Deletion is soft, always. There is no DELETE grant and no DELETE policy anywhere in this
-- file. Hard deletion would take the replies to a practice down with it, and account
-- erasure detaches content rather than destroying it -- which is why author_id is nullable
-- with ON DELETE SET NULL rather than cascading. An erased account leaves an unattributed
-- practice, and the surrounding discussion survives.

create table public.practices (
  id uuid primary key default gen_random_uuid(),

  -- Nullable, and SET NULL rather than CASCADE. This column going null *is* the account
  -- erasure flow: profile data is removed, authored content is detached, and what was
  -- published stays in the corpus under CC BY without a name on it.
  author_id uuid references public.profiles (id) on delete set null,

  status public.content_status not null default 'pending',

  -- ── 1. Title ──────────────────────────────────────────────────────────────────────
  title text not null,

  -- ── 2-3. Area and task type ───────────────────────────────────────────────────────
  area      public.practice_area      not null,
  task_type public.practice_task_type not null,

  -- ── 5. What I was trying to do ────────────────────────────────────────────────────
  -- Hard cap, per the content model. A short aim forces the author to say what the problem
  -- was rather than retell the session; the retelling belongs in `method`.
  aim text not null,

  -- ── 6. What I actually did, stepwise ──────────────────────────────────────────────
  method text not null,

  -- ── 7. Outcome ────────────────────────────────────────────────────────────────────
  outcome       public.practice_outcome not null,
  outcome_notes text not null,

  -- ── 8. How I verified correctness ─────────────────────────────────────────────────
  verification text not null,

  -- ── 9. Transcript ─────────────────────────────────────────────────────────────────
  -- The pasted excerpt is the canonical artifact and lives here. A share link is
  -- supplementary and never the only record: they expire, get revoked, and may breach the
  -- provider's terms. A corpus that pointed at other people's servers would rot.
  transcript_excerpt text,
  transcript_url     text,

  -- ── 10. Caveats ───────────────────────────────────────────────────────────────────
  caveats text,

  -- ── The confirmation, stored with the thing it is about ───────────────────────────
  third_party_material_confirmed boolean not null,

  -- ── 12. Structured metadata ───────────────────────────────────────────────────────
  -- Nullable, because not every practice has a published output to speak of and a forced
  -- answer to an inapplicable question is worse data than no answer.
  time_spent_minutes integer,
  was_published      boolean,
  was_disclosed      boolean,
  -- The site's 11-point scale, same anchors as the agreement scale: 0 no confidence,
  -- 10 complete confidence. Reusing the range means one legend for the whole site.
  author_confidence  smallint,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Soft deletion. Both columns move together or neither does.
  deleted_at timestamptz,
  deleted_by uuid references public.profiles (id) on delete set null,

  -- ── Constraints ───────────────────────────────────────────────────────────────────
  -- Every required text field is checked non-empty *after trimming*. NOT NULL alone lets
  -- a field of three spaces through, which is the oldest hole in form validation and
  -- would put an empty verification section into a corpus whose whole claim is that the
  -- verification section is never empty.

  constraint practices_title_length
    check (length(btrim(title)) between 1 and 120),

  constraint practices_aim_length
    check (length(btrim(aim)) between 1 and 600),

  constraint practices_method_length
    check (length(btrim(method)) between 1 and 6000),

  constraint practices_outcome_notes_length
    check (length(btrim(outcome_notes)) between 1 and 1500),

  -- Stated separately from the length rule so that the error a caller gets names the thing
  -- that matters. "practices_verification_present" is a sentence; a generic length
  -- violation on a field somebody left blank is not.
  constraint practices_verification_present
    check (length(btrim(verification)) >= 1),

  constraint practices_verification_length
    check (length(verification) <= 3000),

  constraint practices_transcript_excerpt_length
    check (transcript_excerpt is null or length(transcript_excerpt) <= 20000),

  -- Shape only. Whether the link resolves is not something a constraint can know, and a
  -- stricter pattern would reject real URLs with brackets and commas in them.
  constraint practices_transcript_url_shape
    check (transcript_url is null
           or (transcript_url ~ '^https?://[^[:space:]]+$' and length(transcript_url) <= 500)),

  constraint practices_caveats_length
    check (caveats is null or length(caveats) <= 2000),

  -- True, not merely present. See the header.
  constraint practices_third_party_material_confirmed
    check (third_party_material_confirmed),

  -- Upper bound is about seventy days of continuous work: high enough never to reject an
  -- honest answer, low enough to catch a field filled in with a year in minutes.
  constraint practices_time_spent_range
    check (time_spent_minutes is null or time_spent_minutes between 1 and 100000),

  constraint practices_author_confidence_range
    check (author_confidence is null or author_confidence between 0 and 10),

  -- You cannot have disclosed AI use in a paper you did not publish. Without this the
  -- corpus accumulates rows saying "not published, disclosure: no", which reads as a
  -- failure to disclose and is actually a question that did not apply.
  constraint practices_disclosure_needs_publication
    check (was_disclosed is null or was_published is true),

  -- A deletion has a time and a hand. Half a soft-delete would hide a row with no record
  -- of who hid it, which is the state a moderation log exists to prevent.
  constraint practices_deletion_all_or_nothing
    check ((deleted_at is null) = (deleted_by is null))
);

comment on table public.practices is
  'First-hand accounts of AI tool use in mathematical work. The corpus. Soft-delete only; '
  'there is no DELETE grant or policy anywhere.';
comment on column public.practices.author_id is
  'Nullable by design. ON DELETE SET NULL is the account erasure path: the account goes, '
  'the contribution stays in the corpus under CC BY without attribution.';
comment on column public.practices.verification is
  'How the author checked the result was correct. Required, with no skip and no "not '
  'applicable". The field that makes this corpus mathematically serious.';
comment on column public.practices.third_party_material_confirmed is
  'The author''s affirmation that third-party unpublished material was removed from the '
  'transcript. Constrained true: the row cannot exist without it.';
comment on column public.practices.transcript_excerpt is
  'The canonical artifact. A share link is supplementary because links expire, are revoked, '
  'and may breach provider terms.';

-- ── Indexes ─────────────────────────────────────────────────────────────────────────
-- Listings sort by recency and filter by the published set, which is one index. The
-- partial predicate matches the read policy exactly, so the common query never touches a
-- pending or deleted row at all.

create index practices_published_recent_idx
  on public.practices (created_at desc)
  where status = 'published' and deleted_at is null;

create index practices_author_idx
  on public.practices (author_id)
  where author_id is not null;

create index practices_area_idx      on public.practices (area);
create index practices_task_type_idx on public.practices (task_type);
create index practices_outcome_idx   on public.practices (outcome);

-- The moderation queue: oldest first, because a submission that has been waiting longest
-- is the one that should be looked at next.
create index practices_pending_idx
  on public.practices (created_at)
  where status = 'pending' and deleted_at is null;

-- ── The guard ───────────────────────────────────────────────────────────────────────
-- SECURITY INVOKER, and this is the same subtlety as private.protect_profile_columns().
-- Inside a DEFINER function current_user is the function's owner, so the trusted check
-- below would see a trusted caller on every browser request, revert nothing, and read in
-- review exactly like a working guard.
--
-- The policies already decide which rows a caller may touch. This decides which *columns*,
-- which policies cannot express: an author may edit their own pending practice freely, but
-- once it is published the only thing they may still change is whether it is deleted.

create function private.protect_practice_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted   boolean;
  v_is_moderator boolean;
begin
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.practices'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  v_is_moderator := exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and p.role in ('moderator', 'admin')
       and not p.is_banned
  );

  -- Immutable for everyone. Reassigning an author would move a contribution onto somebody
  -- else's name, which is the one thing a corpus under CC BY must never do.
  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  if not v_is_moderator then
    -- Status is a moderator's to set. The policies already refuse the update, so this is
    -- the second lock: it holds if a policy is ever loosened by someone adding a feature.
    new.status := old.status;

    -- Restoring a deleted practice is a moderation action, not an authoring one. Without
    -- this, "delete" would be a toggle and a soft-deleted row could be brought back after
    -- the discussion around it had moved on.
    if old.deleted_at is not null then
      new.deleted_at := old.deleted_at;
      new.deleted_by := old.deleted_by;
    end if;

    -- Past pending, the text is fixed. An account of what happened that can be rewritten
    -- after people have confirmed it still works is not a record of anything -- the
    -- confirmations would attest to a version nobody can read any more.
    if old.status <> 'pending' then
      new.title                          := old.title;
      new.area                           := old.area;
      new.task_type                      := old.task_type;
      new.aim                            := old.aim;
      new.method                         := old.method;
      new.outcome                        := old.outcome;
      new.outcome_notes                  := old.outcome_notes;
      new.verification                   := old.verification;
      new.transcript_excerpt             := old.transcript_excerpt;
      new.transcript_url                 := old.transcript_url;
      new.caveats                        := old.caveats;
      new.third_party_material_confirmed := old.third_party_material_confirmed;
      new.time_spent_minutes             := old.time_spent_minutes;
      new.was_published                  := old.was_published;
      new.was_disclosed                  := old.was_disclosed;
      new.author_confidence              := old.author_confidence;
    end if;
  end if;

  return new;
end;
$$;

comment on function private.protect_practice_columns() is
  'Reverts writes to columns the caller does not own. Deliberately SECURITY INVOKER: as '
  'DEFINER, current_user would always be the owner and the guard would never fire.';

revoke all on function private.protect_practice_columns() from public;

create trigger practices_protect_columns
  before update on public.practices
  for each row
  execute function private.protect_practice_columns();

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.practices enable row level security;

-- Anyone, signed in or not, reads the published corpus. This is the policy the whole site
-- is built around, and the partial index above matches it exactly.
create policy practices_select_published
  on public.practices
  for select
  to anon, authenticated
  using (status = 'published' and deleted_at is null);

-- An author sees their own work whatever state it is in, so that a pending submission does
-- not vanish while it waits and a hidden one can be seen to have been hidden.
create policy practices_select_own
  on public.practices
  for select
  to authenticated
  using (author_id = (select auth.uid()));

-- Moderators see everything, including deleted rows: a report about a practice somebody
-- has since deleted still has to be answerable.
create policy practices_select_moderator
  on public.practices
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  );

-- Posting requires a confirmed, unbanned account writing under its own name. Every clause
-- earns its place:
--
--   author_id = auth.uid()   an account cannot post as somebody else
--   status = 'pending'       nothing self-publishes; there is no other way in
--   deleted_at is null       a row cannot be born deleted, which would hide it from the
--                            moderation queue while still counting against a rate limit
--   confirmed_at is not null the address was confirmed. See the migration that added the
--                            column for why this fact has to live on profiles at all
--   not is_banned            a ban means a ban
create policy practices_insert_own
  on public.practices
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and status = 'pending'
    and deleted_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

-- An author edits their own practice while it is pending. The WITH CHECK keeps status
-- pending, so this is not a route to self-publication.
create policy practices_update_own_pending
  on public.practices
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and status = 'pending'
    and deleted_at is null
  )
  with check (
    author_id = (select auth.uid())
    and status = 'pending'
  );

-- An author soft-deletes their own practice at any time, whatever its status. The WITH
-- CHECK requires the resulting row to be deleted, so this policy permits the deletion and
-- nothing else; the guard trigger reverts any text changed in the same statement.
create policy practices_soft_delete_own
  on public.practices
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and deleted_at is null
  )
  with check (
    author_id = (select auth.uid())
    and deleted_at is not null
  );

-- Moderators move things between states. This is the hide path, and nothing ships to real
-- users without one.
create policy practices_update_moderator
  on public.practices
  for update
  to authenticated
  using (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  )
  with check (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  );

-- No DELETE policy, on purpose, matching the absent grant below. Removing a practice
-- outright would take its comments and confirmations with it.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- New tables are not auto-exposed in this project, so without these the table has no
-- endpoint at all. Grants decide whether the endpoint exists; policies decide which rows
-- it returns. A missing grant and a missing policy look identical from the client.

grant select on public.practices to anon, authenticated;

-- INSERT is granted per column. Absent: id, status, created_at, updated_at, deleted_at,
-- deleted_by. So a caller cannot submit something already published even in principle --
-- the column takes its default of 'pending' and Postgres rejects any attempt to name it,
-- before the policy is consulted at all.
grant insert (
  author_id, title, area, task_type, aim, method, outcome, outcome_notes, verification,
  transcript_excerpt, transcript_url, caveats, third_party_material_confirmed,
  time_spent_minutes, was_published, was_disclosed, author_confidence
) on public.practices to authenticated;

-- UPDATE is granted per column too, and `status` is deliberately in the list even though
-- most callers must not write it. Moderators reach PostgREST as the same `authenticated`
-- role as everybody else, so a column grant cannot distinguish them; the moderator policy
-- and the guard trigger are what actually restrict it. Absent: id, author_id, created_at,
-- updated_at.
grant update (
  status, title, area, task_type, aim, method, outcome, outcome_notes, verification,
  transcript_excerpt, transcript_url, caveats, third_party_material_confirmed,
  time_spent_minutes, was_published, was_disclosed, author_confidence,
  deleted_at, deleted_by
) on public.practices to authenticated;

-- No DELETE grant to any application role. Soft-delete only.
