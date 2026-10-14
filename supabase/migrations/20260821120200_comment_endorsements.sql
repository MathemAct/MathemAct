-- public.comment_endorsements — how many people hold a reason, which is not how many people
-- liked it.
--
-- Two actions, for anyone who has answered the debate and did not write the contribution:
-- "this also captures my view", and "I agree with the position, but not this reason". The
-- second exists because without it the first has to carry both meanings, and a reader cannot
-- tell a widely-held reason from a widely-shared conclusion.
--
-- **These are not votes and the difference is not cosmetic.** A vote count ranks
-- contributions against each other; this counts how many people hold a reason. The count is
-- spelled out in words in the interface and never sits beside a heart, a thumb, an arrow or a
-- +1 — that is a copy and rendering rule, recorded here because the table is what makes the
-- number available and the table is what somebody will find first.
--
-- Why SELECT is own-rows-only
-- ---------------------------
-- This is the constraint that shapes the whole table, and it follows from a rule two tables
-- away rather than from anything about endorsement itself.
--
-- A rating row is readable only by its author. That is why public.rating_aggregate is
-- SECURITY DEFINER: a security_invoker view over public.ratings would aggregate exactly one
-- row, the caller's own. And endorsing requires holding a rating.
--
-- So a public list of endorsers would leak, by inference, the private position of every
-- person on it. "This captures my view" on a contribution written from 8 places its endorser
-- near 8 — not exactly, but far more precisely than a table whose whole design is that
-- individual positions are unreadable can afford. The leak is worse for the endorsements that
-- matter most: a contribution written from 0 or from 10 pins its endorsers hard.
--
-- **Counts are public; names are not.** The counts reach a reader through the nightly export
-- like everything else on this site. The browser reads its own rows, and only its own rows, to
-- decide which of the two buttons is currently pressed.
--
-- What is deliberately absent
-- ---------------------------
-- **No SECURITY DEFINER aggregate function.** rating_aggregate has one because a debate's
-- distribution has to be current the moment a reader answers — it is the thing they are shown
-- in exchange for having answered. An endorsement count is not that: it refreshes nightly with
-- the rest of the corpus, and the endorser's own click is covered by optimistic interface
-- state. Adding a live counter here would mean a second DEFINER function on a private table,
-- earning a seventh Security Advisor warning, to save a reader from a number being a day old.
--
-- **No activity trigger, and no change to private.log_activity().** "Somebody endorsed your
-- contribution" cannot name the endorser without undoing the paragraph above, and an
-- endorsement notice that names nobody is a notification saying a number went up. It is also
-- worth not touching log_activity() for its own sake: that function's signature has taken
-- every content write on the site down once already (see 20260819090000), and this feature
-- does not need it.

create type public.endorsement_kind as enum (
  -- The primary action. This contribution says what I would have said.
  'captures_my_view',
  -- The secondary one, and the reason there are two. I am where this person is on the scale,
  -- and I got there another way.
  'agree_position_not_reason'
);

comment on type public.endorsement_kind is
  'Which of the two endorsements. The second exists so that agreeing with a position and '
  'agreeing with a reason are countable separately.';

create table public.comment_endorsements (
  id uuid primary key default gen_random_uuid(),

  -- CASCADE: an endorsement of a contribution that is gone is provenance for nothing. Note
  -- that no route deletes a comment — there is no DELETE grant and no DELETE policy on
  -- public.comments — so in practice this fires only behind an account erasure.
  comment_id uuid not null references public.comments (id) on delete cascade,

  -- CASCADE, matching public.ratings rather than the author columns on content tables. An
  -- endorsement is one person's act rather than a durable contribution: an unattributed one
  -- could not be corrected, could not be counted against the one-per-person rule, and would
  -- leave a count nobody stands behind. Erasure removes them and the counts move.
  user_id uuid not null references public.profiles (id) on delete cascade,

  kind public.endorsement_kind not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One per person per contribution. Changing your mind about which of the two it is is an
  -- UPDATE, which is why `kind` is the only column with an UPDATE grant below.
  constraint comment_endorsements_one_per_user
    unique (comment_id, user_id)
);

comment on table public.comment_endorsements is
  'How many people hold the reason a contribution gives. One row per person per contribution. '
  'Readable only by its author — a public endorser list would leak the private ratings that '
  'endorsing requires. Counts reach readers through the nightly export.';

-- ── Indexes ─────────────────────────────────────────────────────────────────────────
-- The unique constraint already indexes (comment_id, user_id), which serves the export's
-- count-per-contribution and the browser's own-row lookup. The one that is missing is the
-- reverse: everything one person has endorsed, which is what an erasure has to find.

create index comment_endorsements_user_idx
  on public.comment_endorsements (user_id);

-- ── updated_at ──────────────────────────────────────────────────────────────────────
-- Its own function rather than a shared one, so the search path stays pinned and so a change
-- to how ratings are touched cannot arrive here by accident.

create function private.touch_comment_endorsement()
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

revoke all on function private.touch_comment_endorsement() from public;

create trigger comment_endorsements_touch
  before update on public.comment_endorsements
  for each row
  execute function private.touch_comment_endorsement();

-- ── "Has anybody endorsed this?" becomes a column ───────────────────────────────────
-- The edit window on a contribution closes at the first endorsement, and the guard that
-- enforces it — private.protect_comment_columns() — has to be able to ask that question.
-- **It cannot ask this table**, and the reason is worth setting out because the failure would
-- have been silent in the wrong direction.
--
-- The guard is SECURITY INVOKER and must stay so: it is the `current_user` test inside it that
-- distinguishes a browser from the table's owner, and a DEFINER guard sees its own owner on
-- every request. Two consequences follow, and either one alone is fatal to the obvious
-- implementation:
--
--   An `exists` on this table inside the guard runs under the caller's own policies. The caller
--   is the contribution's author, who cannot endorse their own contribution and therefore owns
--   none of its endorsement rows. They would see **zero endorsements however many exist**, so
--   the window would read as closed in the source and be open in production.
--
--   Delegating the read to a DEFINER helper in `private` does not work either. `authenticated`
--   has no USAGE on the private schema — 20260813200000 revoked it and 002_exposure.test.sql
--   asserts it — so the call itself would be refused with 42501, turning every legitimate edit
--   into a permission error.
--
-- So the answer is stored where the guard already is. This is the same move
-- 20260819100000 made for `public.reports.answered_at`, for a different reason — there a
-- subquery recursed, here it lies — and it is cheaper besides: one column read instead of a
-- correlated scan on every update.

alter table public.comments add column endorsed_at timestamptz;

comment on column public.comments.endorsed_at is
  'When this contribution was first endorsed. Closes its edit window. Written only by '
  'private.mark_contribution_endorsed(); no column grant in either direction. Null on every '
  'report comment, which has no endorsement.';

alter table public.comments
  add constraint comments_endorsed_at_debate_only
    check (parent_type = 'debate' or endorsed_at is null);

-- SECURITY DEFINER, and the safe direction of the trap: it asks nothing about who is running
-- the statement. Same shape and same justification as private.mark_report_answered() — the
-- endorser has no privilege on somebody else's contribution and must not need one.
--
-- `where endorsed_at is null` rather than a plain assignment: the first endorsement is the one
-- that freezes the text, a later one must not move the date, and a contribution that already
-- has one is not updated at all — which keeps this from touching a row on every endorsement
-- posted anywhere.
--
-- The stamp is never cleared. Endorsements have no delete path, so in practice this only
-- arises behind an account erasure cascade, and reopening the window then would be wrong: the
-- text was frozen at the moment somebody said it was theirs too, and other people have read it
-- since.

create function private.mark_contribution_endorsed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.comments c
     set endorsed_at = new.created_at
   where c.id = new.comment_id
     and c.endorsed_at is null;

  return null;
end;
$$;

comment on function private.mark_contribution_endorsed() is
  'Stamps public.comments.endorsed_at at the first endorsement, so the SECURITY INVOKER guard '
  'can close the edit window without reading a table it is not permitted to see honestly. '
  'DEFINER because the endorser has no privilege on the contribution.';

revoke all on function private.mark_contribution_endorsed() from public;

create trigger comment_endorsements_mark_contribution
  after insert on public.comment_endorsements
  for each row
  execute function private.mark_contribution_endorsed();

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.comment_endorsements enable row level security;

-- Your own rows and nobody else's. See the header: this is not privacy for its own sake, it
-- is the consequence of ratings being private and endorsement requiring a rating.
create policy comment_endorsements_select_own
  on public.comment_endorsements
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- The five conditions, and every one of them is doing work:
--
--   under your own name, and a confirmed, unbanned account — the same three as every write on
--   this site. `not p.is_banned` here is the ninth copy of that clause.
--
--   the subject is a debate. Report comments have no endorsement, and this is the
--   subject-type condition that keeps it that way.
--
--   not your own contribution. Endorsing your own reason is counting yourself twice: the
--   contribution already carries your position.
--
--   you hold a rating on that debate. The same rule as writing a contribution, for the same
--   reason — an endorsement is agreement from a position, so there has to be a position.
--
-- The subquery on public.comments runs under the caller's own policies, so a hidden
-- contribution is not endorsable without this file having to say so. `deleted_at is null` is
-- said anyway: a soft-deleted contribution keeps its node and its score for the sake of the
-- distribution's provenance, but it has no text left, and endorsing a reason that no longer
-- exists is not a thing to record.
create policy comment_endorsements_insert_own
  on public.comment_endorsements
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
        from public.comments c
        join public.ratings r
          on r.debate_id = c.parent_id
         and r.user_id   = (select auth.uid())
       where c.id = comment_id
         and c.parent_type = 'debate'
         and c.deleted_at is null
         and c.author_id is distinct from (select auth.uid())
    )
  );

-- Changing which of the two it is. Only `kind` has an UPDATE grant, so there is nothing else
-- an update can reach: `comment_id`, `user_id` and `created_at` are refused by the missing
-- column grant with 42501 rather than reverted by a guard, which is the louder of the two
-- behaviours and the right one where no legitimate caller has any reason to try.
--
-- The ban is re-tested here. Without it a banned account could still change its mind about an
-- endorsement, which is a write, and a ban closes writes.
create policy comment_endorsements_update_own
  on public.comment_endorsements
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and not p.is_banned
    )
  );

-- No DELETE policy and no DELETE grant. Withdrawing an endorsement outright is not specified
-- and is not invented here: the two kinds cover "this is my reason" and "the position is mine,
-- the reason is not", and a third state meaning "neither" is what having no row already says.
-- If withdrawal is wanted later it is a DELETE policy and a grant, and it is a decision about
-- whether a count may go down rather than a gap in this table.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Nothing to `anon`. An anonymous reader has no endorsement to read, cannot rate, and so
-- cannot endorse. The counts they see come from the export.

grant select on public.comment_endorsements to authenticated;
grant insert (comment_id, user_id, kind) on public.comment_endorsements to authenticated;
grant update (kind) on public.comment_endorsements to authenticated;
