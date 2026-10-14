-- Withdrawing an endorsement.
--
-- 20260821120200 shipped `public.comment_endorsements` with no DELETE policy and no DELETE
-- grant, and said so explicitly: "If withdrawal is wanted later it is a DELETE policy and a
-- grant, and it is a decision about whether a count may go down rather than a gap in this
-- table." This is that decision, and the answer is yes.
--
-- Why a count may go down
-- ----------------------
-- Because the alternative is worse in a specific way. "This also captures my view" is an
-- assertion about what somebody currently thinks, and the whole design of this section rests on
-- people being able to change their minds and on that being visible rather than hidden — a
-- position change is the most valuable event the section produces. An endorsement that could be
-- given and never taken back would be the one claim on the page its author was stuck with.
--
-- It also follows the shape of the thing it depends on. A rating is changeable, and withdrawing
-- from the scale entirely is an answer rather than a deletion. An endorsement has no equivalent
-- of the off-scale answer, so withdrawal has to be a real delete.
--
-- **This is a hard delete, and the second one on the site.** `public.citations` was the first,
-- for the same reason: there is nothing threaded under an endorsement, no attribution to
-- preserve, and no prose. It is a single fact about one person and one contribution, and the
-- honest way to stop asserting it is for the row to stop existing. A soft delete would leave a
-- row saying "this person once said this captured their view", which is a record nobody asked
-- for and which the select policy would then have to hide from everybody including its author.
--
-- What does not change
-- -------------------
-- **`public.comments.endorsed_at` is not cleared, and the edit window stays shut.** It is
-- stamped by the first endorsement and never reset — 20260821120200 says why, and withdrawal
-- does not weaken it: the text was frozen at the moment somebody said it was theirs too, and
-- other people have read it since on that basis. Reopening an edit window because the one
-- endorser changed their mind would let the words move under everybody who read them.
--
-- The count in the export moves at the next nightly run, like every other number on this site.

-- A banned account cannot withdraw, and that is deliberate rather than an oversight.
--
-- The reasoning is the same as for the rest of a ban: it closes write paths and removes nothing
-- already posted. Their reports stay up, their contributions stay up, and their endorsements
-- stay counted. Permitting this one write would make a ban a way to quietly retract things,
-- which is not what it is for — and `comment_endorsements_update_own` already re-tests the ban
-- for exactly this reason, so admitting a delete without it would be the same rule applied two
-- ways one policy apart.
--
-- Note that this clause is on a DELETE policy and so is **not** one of the nine `not
-- p.is_banned` INSERT clauses the count in docs/moderation.md refers to. Counting it there
-- would make that number wrong in the other direction.

create policy comment_endorsements_delete_own
  on public.comment_endorsements
  for delete
  to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and not p.is_banned
    )
  );

-- Table-wide rather than per column: DELETE has no column list in Postgres, and the policy is
-- what restricts it to the caller's own rows.
grant delete on public.comment_endorsements to authenticated;

comment on table public.comment_endorsements is
  'How many people hold the reason a contribution gives. One row per person per contribution, '
  'withdrawable by its author. Readable only by its author — a public endorser list would leak '
  'the private ratings that endorsing requires. Counts reach readers through the nightly export.';
