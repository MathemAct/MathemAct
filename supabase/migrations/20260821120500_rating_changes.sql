-- public.rating_changes — an append-only record of somebody moving.
--
-- A position change is the most valuable event this section produces. Somebody read the
-- arguments and moved from 6 to 9; that is the thing a corpus of opinion can show that a
-- snapshot cannot, and public.ratings deliberately keeps no history of its own — it reports
-- what people currently think, and a table of every opinion anyone ever held would make "the
-- current distribution" ambiguous. So the movement is recorded beside it rather than inside it.
--
-- **This reverses a decision stated in 20260815160100**, whose header says "Ratings are
-- editable and no history is kept". The half of that sentence which stands is the reason it
-- was written: the *aggregate* is computed from current ratings only, and nothing here changes
-- that. What changes is that the transition is no longer thrown away. The comment on
-- public.ratings is reissued at the bottom of this file so the two tables do not describe the
-- same design in contradictory terms.
--
-- Why both score columns are nullable
-- -----------------------------------
-- Because moving between "no opinion, or outside my expertise" and a number is a real change,
-- and it is the most interesting one on the site. Somebody who declines a formalisation
-- question in March, reads three reports, and comes back with a 7 has done the thing this
-- corpus exists to make possible. A NOT NULL on either column would record every position
-- change except that one. NULL here carries exactly the meaning it carries on
-- public.ratings.score: off the scale, not in the middle of it.
--
-- Why nothing may read it
-- -----------------------
-- **No SELECT grant to `anon` or `authenticated`, and no policy that would give one meaning.**
-- A rating is readable only by its author — that is why public.rating_aggregate is SECURITY
-- DEFINER — and a readable per-person history is a public voting record for a rating that is
-- deliberately private. It would be worse than exposing the rating itself: a current position
-- is one fact, and a trail through somebody's changes of mind is a record of how they think,
-- attached to a name, on a site whose audience includes people contributing pseudonymously
-- because admitting AI reliance carries professional stigma.
--
-- What the table is for is one number per debate in the export: how many participants changed
-- position. The export runs as service role over a direct connection, which is not subject to
-- row level security and needs no grant. Nothing else reads this table, and history is never
-- shown as a voting record.
--
-- It lives in `public` rather than `private` because it is content-adjacent and the export
-- treats it as corpus. With row level security enabled, no policy, and no grant, it has no
-- API endpoint at all: `anon` and `authenticated` cannot reach it even to be refused by a
-- policy, because the endpoint does not exist for them.

create table public.rating_changes (
  id uuid primary key default gen_random_uuid(),

  debate_id uuid not null references public.debates (id) on delete cascade,

  -- CASCADE, matching public.ratings. Erasure removes the person's ratings, and a history of
  -- changes to ratings that no longer exist is a trail attached to nobody that still describes
  -- somebody. Account erasure has to actually work.
  user_id uuid not null references public.profiles (id) on delete cascade,

  -- Both nullable. See the header.
  from_score smallint,
  to_score   smallint,

  changed_at timestamptz not null default now(),

  constraint rating_changes_from_range
    check (from_score is null or from_score between 0 and 10),
  constraint rating_changes_to_range
    check (to_score is null or to_score between 0 and 10),

  -- A row that records no movement is noise, and `is distinct from` is the operator that gets
  -- the NULL cases right: null-to-7 and 7-to-null are both changes, null-to-null is not.
  constraint rating_changes_actually_changed
    check (from_score is distinct from to_score)
);

comment on table public.rating_changes is
  'Append-only record of somebody changing their position on a debate. Both score columns are '
  'nullable because moving to or from "no opinion" is a real change. Unreadable by any browser '
  'role: it exists to produce one count per debate in the export, and a readable per-person '
  'history would be a public voting record for a deliberately private rating.';

comment on column public.rating_changes.from_score is
  'The position held before. NULL means the off-scale answer, not "unknown" — a change row '
  'exists only where a rating row already did.';

-- The export's query: every change on one debate, and the distinct people behind them.
create index rating_changes_debate_idx
  on public.rating_changes (debate_id);

-- ── The writer ──────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER, and the safe direction of the trap: it asks nothing about who is running
-- the statement. It is DEFINER for the same reason private.mark_report_answered() is — the
-- person changing their rating has no INSERT privilege on this table, there is no grant to
-- give them one, and they must not need it.

create function private.log_rating_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.rating_changes (debate_id, user_id, from_score, to_score)
  values (old.debate_id, old.user_id, old.score, new.score);

  return null;
end;
$$;

comment on function private.log_rating_change() is
  'Writes one append-only row when somebody changes their position. DEFINER because the rater '
  'has no privilege on public.rating_changes and must not need one.';

revoke all on function private.log_rating_change() from public;

-- AFTER UPDATE, with the movement test in the WHEN clause rather than in the body: a rating
-- touched without its score changing — which is what an unchanged resubmission is — writes
-- nothing and does not call the function at all.
--
-- `is distinct from` and not `<>`: an author moving from a number to the off-scale answer
-- changes `score` to NULL, and `<>` would evaluate to NULL and silently not fire. That is the
-- single most interesting transition on the site, so it is the one the operator has to get
-- right.
--
-- Only UPDATE. A first answer is not a change of position, and there is no earlier score for
-- `from_score` to hold; the rating row's own created_at is where "when they first answered"
-- lives.
create trigger ratings_log_change
  after update on public.ratings
  for each row
  when (new.score is distinct from old.score)
  execute function private.log_rating_change();

-- ── Row level security ──────────────────────────────────────────────────────────────
-- Enabled with no policies, which means nobody. Every table gets this in the migration that
-- creates it rather than relying on the project default, and here it is belt as well as
-- braces: the absent grant below is what removes the endpoint, and this is what would still
-- refuse a caller if some future migration added one by accident.

alter table public.rating_changes enable row level security;

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- None. Not to `anon`, not to `authenticated`, not for SELECT. The export reaches it as
-- service role, which row level security does not apply to.
--
-- No moderator exception either. A moderator answers flags about published content; nobody's
-- change of mind is content, and there is no moderation decision this table would inform.

-- ── The reversal, recorded where the other half of it lives ─────────────────────────

comment on table public.ratings is
  'One answer per person per debate. Editable, and the aggregate reports what people currently '
  'think — that has not changed. What changed on 2026-08-21 is that the transition is no longer '
  'discarded: public.rating_changes records every movement, append-only and unreadable by any '
  'browser role. This table still holds exactly one row per person, so "the current '
  'distribution" stays unambiguous.';
