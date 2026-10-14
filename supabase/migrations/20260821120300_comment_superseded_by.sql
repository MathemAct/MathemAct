-- Changing a position is an outcome, not an inconsistency.
--
-- When somebody answers a debate again and writes a new contribution, the old one **stays
-- exactly where it was**: same group, same score, same text, same date. It gains a forward
-- link to what replaced it, and that is all that happens to it. Nothing is moved, nothing is
-- deleted, and nothing is rewritten.
--
-- This is the most valuable event this section produces. A person who read the arguments and
-- moved from 6 to 9 is the outcome the whole design is arranged to make visible, and a
-- database that quietly replaced the earlier reasoning would destroy the evidence that it
-- happened. The interface renders the movement as a badge on the earlier contribution; this
-- column is what it renders from.
--
-- Conditional on the subject being a debate, like everything else in this rebuild. A report
-- comment is never superseded — a report thread is a discussion, and a follow-up in a
-- discussion is a reply, which report comments still have.

alter table public.comments
  add column superseded_by uuid references public.comments (id) on delete set null;

comment on column public.comments.superseded_by is
  'The later contribution by the same author on the same debate that replaced this one. Set '
  'server-side by private.supersede_previous_contribution(); never client-writable. The '
  'superseded row keeps its text, its date and its agreement_score — the link is forward only, '
  'and nothing about the earlier position is altered by the author having changed it.';

-- SET NULL rather than CASCADE on the self-reference. If the row this one points at ever
-- disappeared, the correct outcome is an earlier contribution with no forward link — not the
-- deletion of a contribution whose only offence is being pointed at.

alter table public.comments
  add constraint comments_superseded_by_debate_only
    check (parent_type = 'debate' or superseded_by is null);

alter table public.comments
  add constraint comments_no_self_supersede
    check (superseded_by is distinct from id);

comment on constraint comments_superseded_by_debate_only on public.comments is
  'Superseding is a debate-contribution idea. A report comment carries NULL here.';

-- ── The writer ──────────────────────────────────────────────────────────────────────
-- **SECURITY DEFINER, and this is the safe direction of the trap rather than an instance of
-- it.** Nothing in this function asks who is running the statement; it asks which rows are the
-- author's earlier contributions on this debate. That is the same shape as
-- private.mark_report_answered() and private.log_activity(), and the reason is the same in all
-- three: the column has no UPDATE grant in either direction, so the author cannot write it
-- themselves and must not need to.
--
-- Being DEFINER also settles what the guard does with the write. private.protect_comment_columns()
-- is SECURITY INVOKER and tests `current_user` against the table's owner — inside this
-- function `current_user` *is* the owner, so the guard treats it as trusted and returns early
-- without reverting anything. That is exactly the intended division: the guard reverts
-- browsers, and this is not one.
--
-- One visible consequence, recorded because it will otherwise be found by surprise: the guard
-- sets `updated_at := now()` before its trusted check, so superseding bumps `updated_at` on
-- the earlier contribution. The row genuinely did change — it gained a forward link — but
-- `updated_at` on a debate contribution therefore does not mean "the author edited the text".
-- Anything rendering "edited" must read the edit window and the body, not this column.

create function private.supersede_previous_contribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.comments c
     set superseded_by = new.id
   where c.parent_type   = 'debate'
     and c.parent_id     = new.parent_id
     and c.author_id     = new.author_id
     -- Not the row that just arrived. It has a null superseded_by too, so without this it
     -- would supersede itself — which the CHECK above would refuse, turning an ordinary
     -- contribution into a failed insert.
     and c.id           <> new.id
     -- Only the current one. An author on their fourth contribution has three earlier ones,
     -- two of them already superseded and pointing at their own successors; rewriting those
     -- would flatten a chain of four positions into four links to the newest, and the chain
     -- is the record of how somebody arrived where they are.
     and c.superseded_by is null
     -- A soft-deleted contribution has no text left to badge and no reasoning to have moved
     -- on from. Its score stays in the distribution, which is what it is kept for.
     and c.deleted_at    is null;

  return null;
end;
$$;

comment on function private.supersede_previous_contribution() is
  'Links an author''s previous live contribution on a debate forward to the one that replaces '
  'it, in the same transaction. DEFINER because superseded_by has no column grant and the '
  'author must not need one; it asks which rows, never who is running the statement.';

revoke all on function private.supersede_previous_contribution() from public;

-- The WHEN clause is the subject-type condition, in the cheapest available place: the function
-- does not run at all for a report comment. private.mark_report_answered() is attached the
-- same way, in the other direction.
create trigger comments_supersede_previous
  after insert on public.comments
  for each row
  when (new.parent_type = 'debate')
  execute function private.supersede_previous_contribution();

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- None, deliberately, and for the same reason as agreement_score in 20260821120000: INSERT and
-- UPDATE on public.comments are granted per column, so a column nobody names is a column no
-- browser can write. Naming this one would let an author mark somebody else's contribution as
-- superseded by their own, which is a way to write "this person changed their mind" about a
-- person who did not.
--
-- 20260821120400 additionally freezes it in the guard, so that a widened grant would still not
-- be enough on its own.
