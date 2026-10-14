-- Contributions on a debate are flat. Comments on a report are not.
--
-- A report thread is a discussion of one specific account of one specific piece of work, and
-- a remark with the author's answer under it is the shape of a referee's note. That is
-- correct and stays: reports keep one level of nesting, keep replies, and keep an edit window
-- that closes on the first reply.
--
-- A debate is a map of positions. Reading order is claim, then distribution, then
-- contributions grouped by position, then one contribution. A reply belongs to none of those
-- groups — it is a position on a position — and a thread under a contribution is how a map of
-- positions turns back into the chronological wall this section exists not to be.
--
-- **Both halves of the rule below carry the subject-type condition.** A table-wide CHECK
-- forbidding `in_reply_to` would take report threads with it, and `public.comments` is shared.
-- The condition is what makes this a rule about debates rather than a rule about comments.
--
-- Two enforcement points, because they fail differently and both failures are wanted. The
-- policy refuses the write at the endpoint, with the error a policy gives. The CHECK is the
-- statement about the table that survives a policy being rewritten by somebody who did not
-- read this file.

-- ── Anything already threaded ───────────────────────────────────────────────────────
-- Checked rather than assumed, and it refuses rather than repairing. A threaded debate
-- comment is somebody's writing and a reply somebody else made to it; deleting either to let
-- a migration run would destroy content to satisfy a constraint, which is the wrong way round.
-- If this raises, the rows are still there and still readable, and the decision about what to
-- do with them is a person's rather than a migration's.
--
-- The corpus has one debate comment and it is top-level, so this is expected to pass. It is
-- here because a migration that only works against the database it was written on is not
-- finished.

do $$
declare
  v_count integer;
begin
  select count(*)
    into v_count
    from public.comments
   where parent_type = 'debate'
     and in_reply_to is not null;

  if v_count > 0 then
    raise exception
      'There are % threaded comment(s) on debates. Nothing has been deleted and nothing has '
      'been changed: decide what should happen to them, then re-run. They can be found with '
      '"select id, parent_id, in_reply_to from public.comments where parent_type = ''debate'' '
      'and in_reply_to is not null".', v_count
      using errcode = '23514';
  end if;
end;
$$;

-- ── The constraint ──────────────────────────────────────────────────────────────────

alter table public.comments
  add constraint comments_debate_contributions_are_flat
    check (parent_type <> 'debate' or in_reply_to is null);

comment on constraint comments_debate_contributions_are_flat on public.comments is
  'No nesting on a debate. Written with the subject-type condition rather than table-wide '
  'because report threads are one level deep on purpose and share this table.';

-- ── The policy ──────────────────────────────────────────────────────────────────────
-- Dropped and reissued, **not supplemented with a second policy.** Permissive policies on one
-- command are OR'd — both the USING and the WITH CHECK clauses — so a new INSERT policy
-- carrying the flat rule would not add a restriction, it would add an alternative route that
-- grants exactly what the rule withholds. The same reasoning puts the edit window in the
-- guard rather than in a policy, and it is recorded in CLAUDE.md.
--
-- `comments_insert_own` has never been reissued since 20260815180000 created it, so what
-- follows is that policy with one clause added and nothing else changed. The enum labels read
-- 'report' and 'debate' here because 20260817130000 relabelled them in place; the stored
-- expression followed the rename by itself, and this is the first time the text has been
-- written out since.

drop policy comments_insert_own on public.comments;

create policy comments_insert_own
  on public.comments
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and status = 'published'
    and deleted_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
    and (
      (parent_type = 'report'
        and exists (select 1 from public.reports x where x.id = parent_id))
      or
      (parent_type = 'debate'
        and exists (select 1 from public.debates x where x.id = parent_id))
    )
    -- The new clause, and the only change. A reply on a report is still permitted; the
    -- one-level rule that governs it is enforced by private.check_comment_thread() exactly as
    -- before.
    and (parent_type <> 'debate' or in_reply_to is null)
  );

-- Nothing is granted or revoked here. `in_reply_to` keeps its INSERT column grant because a
-- report comment still needs it; what changes is the set of values the policy and the CHECK
-- will accept for a debate.
