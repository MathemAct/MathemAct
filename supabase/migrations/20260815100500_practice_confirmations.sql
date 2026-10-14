-- public.practice_confirmations — "does this still work?"
--
-- The lightest possible contribution, and the one that keeps the corpus honest. An account
-- written against a 2025 model is misleading by 2026, and the only people who can tell us
-- are the ones who try it. One row per person per practice, editable, no history.
--
-- The author may confirm their own practice
-- -----------------------------------------
-- This looks like a hole and is not. The most valuable confirmation anyone will ever file
-- is an author returning to their own account a year later and reporting that it no longer
-- reproduces -- that is the single most likely source of a truthful 'no_longer_works', and
-- forbidding self-confirmation would refuse exactly the report the staleness system exists
-- to collect. The tombstone is not a popularity score, so there is nothing to inflate: it
-- reflects the most recent verdict, whoever filed it.
--
-- Confirmations attach only to published, undeleted practices. Confirming something still
-- in the moderation queue would attest to a version that may yet be edited.

create table public.practice_confirmations (
  id uuid primary key default gen_random_uuid(),

  practice_id uuid not null references public.practices (id) on delete cascade,

  -- CASCADE rather than SET NULL, unlike practices.author_id. A confirmation is not a
  -- contribution to the corpus that survives its author -- it is one person's report, and
  -- an unattributed one could not be corrected, replaced, or counted against the one row
  -- per person rule. Account erasure removes them.
  user_id uuid not null references public.profiles (id) on delete cascade,

  verdict public.confirmation_verdict not null,

  -- Optional and short. Anything longer than a sentence or two is a comment, and comments
  -- are a different table with a different moderation path.
  note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint practice_confirmations_note_length
    check (note is null or length(btrim(note)) between 1 and 500),

  -- One per person per practice. Changing your mind is an update, not a second row: the
  -- tombstone reflects what people currently think, and a table that accumulated every
  -- opinion anyone ever held would make "the latest verdict" ambiguous the first time
  -- somebody filed two in one second.
  constraint practice_confirmations_one_per_user
    unique (practice_id, user_id)
);

comment on table public.practice_confirmations is
  'Reader reports on whether a practice still reproduces. One per person per practice, '
  'editable, no history kept.';
comment on column public.practice_confirmations.user_id is
  'CASCADE on account erasure: a confirmation is one person''s report rather than a durable '
  'contribution, so it goes with them.';

create index practice_confirmations_practice_idx
  on public.practice_confirmations (practice_id, created_at desc);

create index practice_confirmations_user_idx
  on public.practice_confirmations (user_id);

-- ── updated_at, and nothing else ────────────────────────────────────────────────────
-- No guard trigger here, unlike practices and profiles. There are no system-owned columns
-- to protect: every column a caller can reach is theirs, and the ones that are not --
-- id, practice_id, user_id, created_at -- have no UPDATE grant, so Postgres refuses them
-- before any trigger would run.

create function private.touch_confirmation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.touch_confirmation() from public;

create trigger practice_confirmations_touch
  before update on public.practice_confirmations
  for each row
  execute function private.touch_confirmation();

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.practice_confirmations enable row level security;

-- Public, like the practices they attach to. Confirmations are a public act -- the privacy
-- notice lists them under what you post -- and the count of people who have checked is part
-- of what a reader is weighing.
create policy practice_confirmations_select_with_parent
  on public.practice_confirmations
  for select
  to anon, authenticated
  using (
    exists (select 1 from public.practices p where p.id = practice_id)
  );

-- Same account requirements as posting a practice: confirmed address, not banned, writing
-- under its own id. A confirmation moves a tombstone from open to filled on a public
-- listing, so it is a claim about correctness and is gated like one.
create policy practice_confirmations_insert_own
  on public.practice_confirmations
  for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
    and exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.status = 'published'
         and p.deleted_at is null
    )
  );

create policy practice_confirmations_update_own
  on public.practice_confirmations
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Withdrawing a verdict is a delete, so that "I no longer have an opinion" is
-- representable. Without it the only way out of a verdict would be to hold a different
-- one, which is not the same thing.
create policy practice_confirmations_delete_own
  on public.practice_confirmations
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- Moderators are deliberately absent from this table. A confirmation is a report rather
-- than content: the moderation answer to a bad-faith one is the ban on the account, which
-- the insert policy already honours, not an edit to what somebody said they observed.

-- ── Grants ──────────────────────────────────────────────────────────────────────────

grant select on public.practice_confirmations to anon, authenticated;
grant insert (practice_id, user_id, verdict, note) on public.practice_confirmations to authenticated;
grant update (verdict, note) on public.practice_confirmations to authenticated;
grant delete on public.practice_confirmations to authenticated;
