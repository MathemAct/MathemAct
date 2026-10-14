-- Two guards that keep a confirmation's verdict answering the question its report asks,
-- and the tombstone rule rewritten to read both questions.
--
-- 20260823100000 added 'still_fails' and 'now_works' to public.confirmation_verdict. This
-- file is what makes them mean something: which pair of values is allowed on a given
-- report is decided by that report's outcome, and nothing may leave the two out of step.
--
-- The pairing cannot be a CHECK constraint. A CHECK may not read another table, and the
-- outcome lives on public.reports. So it is two BEFORE triggers, one on each side of the
-- relationship, because there are two ways to break the pairing and a guard on one table
-- catches only one of them:
--
--   1. Filing a verdict that does not match the report's outcome.
--   2. Changing the report's outcome out from under a verdict already filed.
--
-- The second is not hypothetical, and it is narrower than it looks. A confirmation by
-- anybody other than the author stamps reports.answered_at and freezes the whole report,
-- so that route is already shut. What is left is the author's own confirmation on their own
-- report, which is deliberately allowed (see docs/decisions.md, "An author may confirm
-- their own report") and does not freeze anything. Without guard 2, an author could confirm
-- their own report 'still_works' and then edit the outcome to 'failed', leaving a verdict
-- on the record answering a question the report no longer asks.

-- ── Why both guards are SECURITY INVOKER ────────────────────────────────────────────
-- Neither asks who is running the statement, so neither has to be INVOKER for the reason
-- private.protect_profile_columns() does. They are INVOKER because they do not need to be
-- DEFINER, and DEFINER is the direction that fails silently.
--
-- The usual objection does not apply here, and it is worth saying why, because this schema
-- has two tables where it would. A SECURITY INVOKER guard cannot ask "has anybody else
-- rated this?" or "has anybody endorsed this?" — public.ratings and
-- public.comment_endorsements are readable only by their own author, so the guard is told
-- "nobody" however many rows exist. That is why comments.endorsed_at and debates.answered_at
-- are stored columns.
--
-- Both tables read here are ordinary public-readable ones:
--
--   * public.reports — a published, undeleted report is readable by anon and authenticated,
--     and the insert policy on report_confirmations already requires the parent to be
--     exactly that. An author also sees their own report whatever its status.
--   * public.report_confirmations — its select policy is "the parent exists", not "the row
--     is yours". An author updating their own report can see every confirmation on it.
--
-- So both guards see everything they need to, and storing a column would be answering a
-- question that is already answerable.

-- ── Why the pairing is written out twice ────────────────────────────────────────────
-- The obvious cleanup is one helper — private.verdicts_for_outcome(report_outcome) — called
-- by both guards. It does not work, and the failure is a 42501 at the moment a user tries
-- to confirm something.
--
-- `authenticated` holds no USAGE on the private schema. A trigger *fires* without a
-- privilege check on its own function, which is why these two work at all, but any
-- private.* function called from inside an INVOKER trigger body is refused. The helper
-- would have to live in public and be granted EXECUTE to browser roles, which is a public
-- API surface for an implementation detail.
--
-- The duplication is therefore deliberate. There are two copies of the pairing here and a
-- third in verdictsFor() in src/lib/status.ts, and they have to be changed together.

create function private.check_confirmation_verdict()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_outcome public.report_outcome;
begin
  select r.outcome into v_outcome
    from public.reports r
   where r.id = new.report_id;

  -- No visible parent. Not this guard's error to raise: the insert policy refuses the row
  -- a moment later and says the right thing about it. Inventing a second message here would
  -- mean two different errors for one cause, and this one would win.
  if v_outcome is null then
    return new;
  end if;

  if v_outcome = 'failed' then
    if new.verdict not in ('still_fails', 'now_works') then
      raise exception
        'This report says the attempt did not work, so the question is whether it still '
        'does not. Answer "it still does not work" or "it works now".'
        using errcode = '23514';
    end if;
  else
    if new.verdict not in ('still_works', 'no_longer_works') then
      raise exception
        'This report says the attempt worked, so the question is whether it still works. '
        'Answer "it still works" or "it no longer works".'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

comment on function private.check_confirmation_verdict() is
  'Refuses a confirmation whose verdict answers the other question. INVOKER: it reads only '
  'public.reports, which the caller can already see, and asks nothing about who is running '
  'the statement.';

revoke all on function private.check_confirmation_verdict() from public;

create trigger report_confirmations_verdict_matches_outcome
  before insert or update on public.report_confirmations
  for each row
  execute function private.check_confirmation_verdict();

-- ── Neither guard exempts a trusted role, and that is on purpose ────────────────────
-- private.protect_report_columns() lets `service_role` and the table owner straight
-- through, because it is a guard about privilege: it exists to stop an author rewriting
-- their own attested text, and an administrator repairing data is not that author.
--
-- These two are not about privilege. They are the cross-table CHECK constraint Postgres
-- will not let us write, and a CHECK does not exempt the owner either. A migration that
-- really does mean to move an outcome out from under a live verdict can disable the
-- trigger for the length of one statement, which is a visible, reviewable thing to have
-- written; being silently allowed to orphan a verdict is not.

-- ── Guard 2: the outcome cannot move away from a verdict already filed ──────────────
-- Only a move across the 'failed' boundary is refused. 'worked' and 'partial' ask the same
-- question and take the same two answers, so an author correcting "it worked" to "it partly
-- worked" — which is the common correction, and an honest one — is left alone.

create function private.check_outcome_matches_confirmations()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_allowed public.confirmation_verdict[];
begin
  v_allowed := case
    when new.outcome = 'failed' then array['still_fails', 'now_works']::public.confirmation_verdict[]
    else array['still_works', 'no_longer_works']::public.confirmation_verdict[]
  end;

  if exists (
    select 1
      from public.report_confirmations c
     where c.report_id = new.id
       and not (c.verdict = any (v_allowed))
  ) then
    raise exception
      'This report already has a confirmation answering whether it still works. Changing '
      'the outcome would leave that answer attached to a different question. Withdraw the '
      'confirmation first, or if it is not yours, post a correction rather than editing '
      'the outcome.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

comment on function private.check_outcome_matches_confirmations() is
  'Refuses an outcome change that would orphan a confirmation already filed against the '
  'other question. In practice this only ever fires on an author''s own confirmation of '
  'their own report, which is the one confirmation that does not freeze the report.';

revoke all on function private.check_outcome_matches_confirmations() from public;

-- ── The name of this trigger is load-bearing ────────────────────────────────────────
-- BEFORE ROW triggers on one table fire in alphabetical order by trigger name, and a WHEN
-- clause is evaluated against NEW *as previous triggers have already modified it*. Both
-- facts matter here, because the other guard on this table reverts rather than raises.
--
-- private.protect_report_columns() runs as `reports_protect_columns` and, on a report
-- somebody else has answered, assigns `new.outcome := old.outcome` — the statement then
-- succeeds having changed nothing, which is the documented behaviour and is relied on:
-- an author who sends one UPDATE that both deletes their report and sneaks a content
-- change gets the deletion the policy permits and none of the sneak.
--
-- `reports_verdicts_match_outcome` sorts after `reports_protect_columns` ('v' after 'p').
-- So on a frozen report the revert lands first, this trigger's WHEN clause is then false,
-- and the raise never happens — the silent revert is preserved exactly. Rename this to
-- anything sorting before 'p' and a frozen report's harmless no-op becomes an exception
-- that aborts the legitimate half of the same statement.
--
-- What is left to raise on is the report the guard does *not* freeze: one whose only
-- confirmation is the author's own (which never sets answered_at), and one a moderator has
-- hidden (which its author may still edit). Those are exactly the cases where the outcome
-- is genuinely about to move under a live verdict.
--
-- The WHEN clause also keeps this off every other update to every other report.
-- Moderation, the activity triggers and the stamping of answered_at all update
-- public.reports, and none of them touches the outcome.
create trigger reports_verdicts_match_outcome
  before update on public.reports
  for each row
  when (old.outcome is distinct from new.outcome)
  execute function private.check_outcome_matches_confirmations();

-- ── The tombstone rule, rewritten ───────────────────────────────────────────────────
-- The view is otherwise unchanged from 20260815100600 (via the rename in 20260817130000):
-- same columns, same order, same lateral joins, same twelve-month literal and the same
-- reason for it being a literal. What changes is that both verdict pairs are now read, and
-- what the fourth status is called.
--
-- 'broken' is now 'changed'. The old name and its label, "No longer works", were right for
-- the only case that could arise: a report that worked and stopped. It is wrong for the case
-- this migration makes possible — a report that failed and now works — and calling that
-- "broken" would tell a reader the opposite of what happened. The status means "somebody has
-- since reported a different result"; the words for it are composed from the outcome in
-- src/lib/status.ts, which is where a tombstone's accessible name has always been assembled
-- from both axes.
--
-- A verdict that the account still holds — 'still_works' on a success, 'still_fails' on a
-- failure — is what fills the square, and this is not a new decision. src/lib/status.ts has
-- said since it was written that "a report can report 'did not work' and still be verified
-- and current". The question was simply never asked in a form that let anyone say it. A
-- reproduced failure is a first-class result and gets a filled square, on the same terms as
-- a reproduced success.

create or replace view public.report_staleness
with (security_invoker = on) as
select
  p.id as report_id,

  -- The most recent tool use across every tool on the report. A session that used one
  -- model in March and a proof assistant in June is as current as its newest part: the
  -- question a reader is asking is "has anything moved since this was written", and the
  -- newest date is what answers it.
  t.latest_tool_use,

  c.latest_verdict,
  c.latest_confirmation_at,

  -- Coalesced, because the lateral below returns no row at all for a report nobody has
  -- confirmed and the left join would make that a null. "Null people have checked this" is
  -- not a fact about anything, and every consumer would have to remember to coalesce it;
  -- one of them would not.
  coalesce(c.confirmation_count, 0) as confirmation_count,

  -- The four statuses, matching TOMBSTONE_STATUS in src/lib/status.ts exactly. Order
  -- matters: a report that the result has changed outranks everything, because it is the one
  -- piece of information a reader most needs before spending an afternoon on it — and that
  -- is true in both directions now. "This stopped working" saves the afternoon; "somebody
  -- got this working since" is the reason to spend it.
  case
    when c.latest_verdict in ('no_longer_works', 'now_works') then 'changed'
    when c.latest_verdict in ('still_works', 'still_fails')
         and c.latest_confirmation_at >= now() - interval '12 months' then 'verified'
    -- Reproduced, but long enough ago that the model has almost certainly changed
    -- underneath it. Still open, and honestly so.
    when c.latest_verdict in ('still_works', 'still_fails') then 'stale'
    -- Never confirmed by anyone, and written against a tool used over a year ago.
    when t.latest_tool_use < current_date - interval '12 months' then 'stale'
    else 'unverified'
  end as tombstone_status,

  -- The filled square, in one boolean, so that nothing rendering a list has to re-derive
  -- it from the string above and get the comparison subtly wrong.
  --
  -- Coalesced for a sharper reason than the count above. With no confirmation the
  -- comparison is null rather than false, and null is falsy in JavaScript but renders as
  -- "unknown" in SQL and as `null` in the JSON export -- so the same report would be
  -- open in the interface and unclassifiable in the corpus. A square is filled or it is
  -- not; there is no third state, and the type should not offer one.
  --
  -- `in` returns null on a null verdict, and `null and true` is null, so the coalesce is
  -- load-bearing here exactly as it was with the equality it replaces.
  coalesce(
    c.latest_verdict in ('still_works', 'still_fails')
    and c.latest_confirmation_at >= now() - interval '12 months',
    false
  ) as is_verified

from public.reports p

-- LATERAL rather than a grouped join, so that a report with no tools or no confirmations
-- still produces exactly one row. An inner join would silently drop the unconfirmed
-- reports, which are the majority and the ones the open square is for.
left join lateral (
  select max(pt.used_on) as latest_tool_use
    from public.report_tools pt
   where pt.report_id = p.id
) t on true

left join lateral (
  select
    pc.verdict    as latest_verdict,
    pc.created_at as latest_confirmation_at,
    (select count(*)
       from public.report_confirmations n
      where n.report_id = p.id) as confirmation_count
  from public.report_confirmations pc
  where pc.report_id = p.id
  -- Most recent wins outright. id breaks a tie so the result is deterministic rather than
  -- whatever the planner returns first, which would make a tombstone flicker between two
  -- values on successive page loads.
  order by pc.created_at desc, pc.id desc
  limit 1
) c on true;

comment on view public.report_staleness is
  'Per report: most recent tool use, latest confirmation, and the derived tombstone. A '
  'verdict that the account still holds -- still_works on a success, still_fails on a '
  'failure -- fills the square; either verdict that it has changed opens it. SECURITY '
  'INVOKER -- without it this view would return hidden reports to anonymous callers.';

-- create or replace keeps the existing grants, and this restates rather than repairs them.
-- A missing grant and a missing policy are indistinguishable from the browser, so the one
-- that is cheap to be sure about is written down.
grant select on public.report_staleness to anon, authenticated;
