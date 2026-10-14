-- "Has somebody else answered this?" becomes a column, because nothing that asks can see.
--
-- `023_submit_debate.test.sql` failed two assertions on the first run in which it got far enough
-- to make them: an author rewrote their claim after somebody else had answered it, and added a
-- tag after the same, and both succeeded. The rule was written correctly in two places and was
-- unenforceable in both.
--
-- **A rating row is readable only by its author.** `ratings_select_own` is
-- `using (user_id = (select auth.uid()))`, which is the promise the whole scale rests on and is
-- why `public.rating_aggregate` has to be DEFINER. Two consequences, and each one alone is fatal
-- to the obvious implementation:
--
--   `private.protect_debate_columns()` is SECURITY INVOKER — it must be, because it is its
--   `current_user` test that distinguishes a browser from the table's owner — so its
--   `exists (select 1 from public.ratings ...)` runs under the caller's own policies. The caller
--   is the claim's author. They can see exactly one rating: their own. Excluding it, as
--   20260822110250 correctly does, leaves the EXISTS with nothing to find **however many other
--   people have answered**, so the wording never freezes.
--
--   The `debate_tags` write policies read the same table from the same position and fail the same
--   way. A policy's subquery is evaluated as the caller too.
--
-- Worth recording that the version before 20260822110250 was also broken, differently and less
-- visibly: `exists (select 1 from public.ratings r where r.debate_id = old.id)` found the
-- author's own rating when they had one and nothing at all when they had not — so the freeze
-- engaged on the author's own answer and never on anybody else's. It has never done what it says.
--
-- This is the second time this schema has met this exact shape. `comments.endorsed_at` exists
-- because a SECURITY INVOKER guard cannot honestly read `public.comment_endorsements`, which is
-- own-rows-only for the same reason — and `public.reports.answered_at` exists because a policy
-- could not read `public.comments` without recursing. **When a guard needs an answer it may not
-- compute, store the answer.** Delegating to a DEFINER helper is not the alternative here:
-- `authenticated` holds no USAGE on the `private` schema, so neither the guard nor a policy could
-- call one.

alter table public.debates add column answered_at timestamptz;

comment on column public.debates.answered_at is
  'When somebody other than the author first rated this debate. Null means nobody has, and the '
  'author may still correct the wording and the tags. Written only by '
  'private.mark_debate_answered(); there is no column grant for it in either direction. It exists '
  'because the guard and the tag policies cannot read public.ratings — a rating is readable only '
  'by its author, so an author asking "has anybody else answered?" is told no.';

-- ── Existing rows ───────────────────────────────────────────────────────────────────
-- Any debate somebody other than its author has already rated is answered, and its wording
-- should be frozen from the moment this migration lands rather than from the next rating.
--
-- `is distinct from` and not `<>`: `author_id` is nullable, because erasure detaches a debate
-- rather than deleting it, and on a detached debate `<>` would evaluate to NULL for every rating
-- and the backfill would skip a claim dozens of people had answered.

update public.debates q
   set answered_at = answers.first_at
  from (
    select r.debate_id, min(r.created_at) as first_at
      from public.ratings r
      join public.debates d on d.id = r.debate_id
     where r.user_id is distinct from d.author_id
     group by r.debate_id
  ) as answers
 where q.id = answers.debate_id;

-- ── The writer ──────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER, and this is the safe direction of the trap rather than an instance of it:
-- nothing here asks who is running the statement. It is DEFINER for the same reason
-- `private.mark_report_answered()` is — somebody rating a debate has no UPDATE privilege on it,
-- and must not need one to leave a mark on it.
--
-- `where answered_at is null` rather than a plain assignment: the first answer is the one that
-- freezes the claim, a later one must not move the date forward, and a debate that already has
-- one is not updated at all — which keeps the guard and the activity trigger on public.debates
-- from firing on every rating cast anywhere.

create function private.mark_debate_answered()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.debates q
     set answered_at = new.created_at
   where q.id = new.debate_id
     and q.answered_at is null
     -- Your own answer is not an answer. A proposer is required to place themselves on the scale
     -- (20260822110300), so without this every debate would be frozen at the moment it was
     -- created and no author could ever fix a typo in their own claim.
     and q.author_id is distinct from new.user_id;

  return null;
end;
$$;

comment on function private.mark_debate_answered() is
  'Stamps public.debates.answered_at the first time somebody other than the author rates it. '
  'DEFINER because a rater has no privilege on the debate and must not need one.';

revoke all on function private.mark_debate_answered() from public;

-- INSERT only. Somebody changing their answer does not change whether the debate has been
-- answered, and re-stamping on update would move a date whose whole job is to be the first one.
create trigger ratings_mark_debate_answered
  after insert on public.ratings
  for each row
  execute function private.mark_debate_answered();

-- ── The guard, reading the column instead of the table ──────────────────────────────
-- Reissued whole rather than patched, per the standing rule for this project's guards. Identical
-- to 20260822110250's version except for the freeze condition and the newly frozen column.
--
-- SECURITY INVOKER, and load-bearing: inside a DEFINER function `current_user` is the function's
-- owner, so the trusted check below would pass on every browser request and the guard would
-- revert nothing while reading exactly like one that works.

create or replace function private.protect_debate_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.debates'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  -- Promotion and hiding are decisions, and decisions are logged. public.moderate() is the
  -- only route to either.
  new.status       := old.status;
  new.activated_at := old.activated_at;

  -- Written only by private.mark_debate_answered(), which arrives as the owner and is let
  -- through by the trusted check above. Frozen here as well as ungranted, so that a widened
  -- grant would still not be enough on its own to unfreeze a claim.
  new.answered_at := old.answered_at;

  -- The wording is fixed once somebody other than the author has answered. People answered the
  -- sentence in front of them, and an author who could reword it afterwards would be reassigning
  -- their agreement to a claim they never saw.
  --
  -- **Read off the row, not out of public.ratings.** See the header: a rating is readable only by
  -- its author, so this guard — which runs as the author — is told there are no other answers
  -- however many there are. Two versions of this rule were unenforceable before the column
  -- existed.
  if old.answered_at is not null then
    new.statement := old.statement;
    new.area      := old.area;
  end if;

  return new;
end;
$$;

comment on function private.protect_debate_columns() is
  'Freezes id, author, dates, status and answered_at, and freezes the wording once '
  'answered_at is set — which is when somebody other than the author has rated. SECURITY '
  'INVOKER: inside a DEFINER function current_user is the owner, so the trusted check would '
  'admit every browser request.';

revoke all on function private.protect_debate_columns() from public;

-- ── The tag policies, reading the same column ───────────────────────────────────────
-- Dropped and reissued rather than supplemented. Permissive policies on one command are OR'd, so
-- a second policy carrying the corrected condition would not narrow anything — it would add an
-- alternative route that grants exactly what the correction withholds.

drop policy debate_tags_insert_own_unanswered on public.debate_tags;
drop policy debate_tags_delete_own_unanswered on public.debate_tags;

create policy debate_tags_insert_own_unanswered
  on public.debate_tags
  for insert
  to authenticated
  with check (
    exists (
      select 1
        from public.debates q
       where q.id = debate_id
         and q.author_id = (select auth.uid())
         -- The same column, for the same reason: this subquery cannot see somebody else's
         -- rating either, so it must not be asked to look for one.
         and q.answered_at is null
    )
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

create policy debate_tags_delete_own_unanswered
  on public.debate_tags
  for delete
  to authenticated
  using (
    exists (
      select 1
        from public.debates q
       where q.id = debate_id
         and q.author_id = (select auth.uid())
         and q.answered_at is null
    )
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and not p.is_banned
    )
  );

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- None for `answered_at`, deliberately, and recorded here rather than left to look like an
-- omission. INSERT and UPDATE on public.debates are granted per column — see 20260822110200 —
-- so a column nobody names is a column no browser can write. An author who could write this one
-- could unfreeze their own claim after people had answered it, which is the whole thing the
-- column exists to prevent.
