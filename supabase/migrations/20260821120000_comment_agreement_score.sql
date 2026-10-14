-- A debate contribution carries the position it was written from.
--
-- `public.comments` serves reports and debates, and **everything in this file is conditional
-- on the subject being a debate.** A report comment gets a NULL in the new column and is
-- otherwise untouched: it keeps its replies, keeps one level of nesting, and keeps an edit
-- window that closes on the first reply. Any constraint here without a `parent_type` term in
-- it would silently change report threads, which are the one place on this site where
-- threading is correct.
--
-- Why the score is stored rather than joined
-- ------------------------------------------
-- The obvious implementation is a view joining a contribution to its author's live rating.
-- It is wrong. Somebody who changes their mind would drag every contribution they have ever
-- written into a different group, retroactively — so the record of what the community
-- thought in March would silently become a record of what those same people think today.
-- A contribution is written *from* a position, and that position is a fact about the moment
-- it was written. It is copied here once and frozen.
--
-- **A NULL agreement_score on a debate comment means "no opinion / outside my expertise".
-- It does not mean "unset".** This is the reading the next person will get wrong, so it is
-- worth being exact about why it cannot mean anything else.
--
-- The agreement scale carries an explicit off-scale option, and it is stored as a NULL
-- `score` on a real `public.ratings` row — not as an absent row. See 20260815160100. The
-- trigger below refuses any debate contribution whose author holds no rating row at all.
-- Between those two facts the column is unambiguous by construction: a debate contribution
-- exists only where a rating row exists, so a NULL here can only have been copied from a
-- NULL there, which is somebody saying "I was asked and I decline".
--
-- Therefore: no sentinel value, no coercion to 5, and no second boolean to disambiguate.
-- A sentinel would put a non-answer on the scale; coercing to 5 would file a declared
-- non-opinion as a neutral opinion, which is the exact corruption the off-scale option
-- exists to prevent; and a companion boolean would be a second source of truth for a fact
-- the column already carries.

alter table public.comments add column agreement_score smallint;

comment on column public.comments.agreement_score is
  'The author''s position on the debate at the moment this contribution was written, copied '
  'from their rating row by private.set_comment_agreement_score() and frozen. NULL on a '
  'debate comment means "no opinion / outside my expertise" — never "unset", because a '
  'contribution cannot exist without a rating row. Always NULL on a report comment. Not '
  'granted for INSERT or UPDATE to any browser role.';

-- The range, matching public.ratings.ratings_score_range. Nullable for the reason above.
alter table public.comments
  add constraint comments_agreement_score_range
    check (agreement_score is null or agreement_score between 0 and 10);

-- The subject-type condition. This says nothing about a report comment except that it
-- carries no score, which is the whole of what a report comment has to do with this feature.
alter table public.comments
  add constraint comments_agreement_score_debate_only
    check (parent_type = 'debate' or agreement_score is null);

comment on constraint comments_agreement_score_debate_only on public.comments is
  'A position belongs to a debate contribution. A report comment carries NULL here, and this '
  'is the condition that keeps the feature out of report threads.';

-- ── Setting it ──────────────────────────────────────────────────────────────────────
-- **The trigger overwrites whatever arrived rather than raising on a mismatch**, and that is
-- a deliberate choice between two defences that are not equally sturdy.
--
-- Raising on a mismatch only works while the column is ungranted: it turns a lie into an
-- error, but it depends on the client having been able to name the column at all in order to
-- be wrong about it. Overwriting does not care. Grant the column tomorrow by accident, add a
-- service-role path, widen a column list in a migration that is about something else — and
-- the value is still the one read out of the rating row, because the last write before the
-- row lands is this one. The grant is still withheld below; this is the defence that does
-- not depend on it.
--
-- **SECURITY INVOKER**, and that is correct here rather than merely conventional. The
-- function reads the caller's own rating row, which `ratings_select_own` already grants them,
-- so it needs no elevation at all. Making it DEFINER would buy nothing and would step into
-- the trap this project has already paid for once: inside a DEFINER function `current_user`
-- is the function's owner, so anything that later grew a trusted-caller check in here would
-- pass it on every browser request. INVOKER also means the lookup obeys row level security,
-- so a rating this caller may not read is a rating that does not exist for this purpose —
-- which is the same answer, arrived at by the same rule as everywhere else.

create function private.set_comment_agreement_score()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_score smallint;
begin
  -- A report comment. Overwritten to NULL rather than left alone, so that the column is
  -- right even if a caller sent something, and so the CHECK above is a statement about the
  -- table rather than a statement about what the interface happens to submit.
  if new.parent_type <> 'debate' then
    new.agreement_score := null;
    return new;
  end if;

  select r.score
    into v_score
    from public.ratings r
   where r.debate_id = new.parent_id
     and r.user_id   = new.author_id;

  -- No rating row. You cannot contribute to a debate you have not answered, and that is a
  -- feature rather than an obstacle: a contribution is a reason for a position, so a
  -- contribution from nowhere on the scale has no position to be the reason for.
  --
  -- FOUND is the right test and `v_score is null` is not. A rater who chose the off-scale
  -- option has a row whose score is NULL, and FOUND is true for them — they have answered,
  -- they may contribute, and the NULL is carried across as their position. Testing the value
  -- instead of the row would refuse exactly the people the off-scale option was added for.
  if not found then
    raise exception
      'Answer this debate before writing a contribution. A contribution is the reason for a '
      'position, so it needs a position to be the reason for — including "no opinion, or '
      'outside my expertise", which counts as answering.'
      using errcode = '23514';
  end if;

  new.agreement_score := v_score;
  return new;
end;
$$;

comment on function private.set_comment_agreement_score() is
  'Copies the author''s current rating into a new debate contribution and refuses one from '
  'somebody who has not rated. Overwrites rather than raising on a mismatch, so it does not '
  'depend on the column staying ungranted. SECURITY INVOKER: it reads the caller''s own '
  'rating and needs no elevation.';

revoke all on function private.set_comment_agreement_score() from public;

-- The name sorts after `comments_check_thread` and `comments_daily_limit`, and the order is
-- deliberate for the same reason theirs is: a malformed reply is refused as malformed rather
-- than as unrated, so the error a caller gets names the thing they can actually fix.
create trigger comments_set_agreement_score
  before insert on public.comments
  for each row
  execute function private.set_comment_agreement_score();

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- INSERT and UPDATE on public.comments are granted **per column** (20260815180000), so a new
-- column is unwritable by a browser until somebody names it in a GRANT. Nothing here names
-- it, and nothing should.
--
-- This is the one case where the standing rule — a migration that adds a column to a
-- per-column-granted table issues the GRANT in the same file — is deliberately not followed,
-- so the omission is recorded here rather than left to look like a mistake. A caller who can
-- name this column can lie about which group their contribution belongs to, and the group is
-- the entire point of the column.
--
-- The observable behaviour of the two defences differs and both are wanted: naming the column
-- in an INSERT is refused outright with 42501 by the missing grant, and a value that reaches
-- the trigger by any other route is silently replaced. The first is a closed door; the second
-- is a floor under it.
