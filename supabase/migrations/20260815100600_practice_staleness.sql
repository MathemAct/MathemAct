-- public.practice_staleness — whether the tombstone on a practice is filled or open.
--
-- The tombstone is the signature element of this site: a filled square means a correctness
-- verification is on record and somebody has confirmed the practice still works, an open
-- one means it is unverified, stale, or reported broken. It is the status system, the list
-- bullet, and the section divider, and it encodes something true rather than decorating.
--
-- The rule lives here, in SQL, and not in the frontend. Three reasons, and the third is the
-- one that matters:
--
--   1. The same answer has to appear in a listing, on a practice page, in the nightly JSON
--      export, and in whatever a researcher runs against the dumped corpus. Four
--      implementations would be four subtly different definitions of "verified".
--   2. Reads are served from static files built from the export. A rule that lived in
--      TypeScript would run at build time over data that had already lost the inputs.
--   3. A definition in the interface is a claim nobody can check. This one can be read,
--      queried, and argued with, which for a corpus whose entire pitch is that it is
--      structured evidence is not a nicety.
--
-- SECURITY INVOKER, and this is not optional
-- ------------------------------------------
-- A view has no row level security of its own. By default it runs with its creator's
-- privileges, which here means the migration role, which means it would cheerfully return
-- pending and hidden practices to anonymous callers -- while looking completely correct in
-- review, because the policies on the underlying tables are right and simply are not
-- consulted. `security_invoker = on` makes every underlying read happen as the caller.
-- 010_practice_staleness.test.sql asserts an anonymous client sees no pending row through
-- this view, which is the test that would catch its removal.

-- ── The staleness window ────────────────────────────────────────────────────────────
-- Twelve months, written as a literal below rather than read from private.settings.
--
-- That is a deliberate limitation. The view is SECURITY INVOKER, so every name in it is
-- resolved with the caller's privileges, and anonymous callers have no USAGE on the private
-- schema -- a settings lookup here would fail for exactly the readers the view exists to
-- serve. Changing the window is therefore a migration, which is the right weight for a
-- number that changes the meaning of every tombstone on the site at once.

create view public.practice_staleness
with (security_invoker = on) as
select
  p.id as practice_id,

  -- The most recent tool use across every tool on the practice. A session that used one
  -- model in March and a proof assistant in June is as current as its newest part: the
  -- question a reader is asking is "has anything moved since this was written", and the
  -- newest date is what answers it.
  t.latest_tool_use,

  c.latest_verdict,
  c.latest_confirmation_at,

  -- Coalesced, because the lateral below returns no row at all for a practice nobody has
  -- confirmed and the left join would make that a null. "Null people have checked this" is
  -- not a fact about anything, and every consumer would have to remember to coalesce it;
  -- one of them would not.
  coalesce(c.confirmation_count, 0) as confirmation_count,

  -- The four statuses, matching TOMBSTONE_STATUS in src/lib/status.ts exactly. Order
  -- matters: a report that something is broken outranks everything, because it is the one
  -- piece of information a reader most needs before spending an afternoon on it.
  case
    when c.latest_verdict = 'no_longer_works' then 'broken'
    when c.latest_verdict = 'still_works'
         and c.latest_confirmation_at >= now() - interval '12 months' then 'verified'
    -- Confirmed working, but long enough ago that the model has almost certainly changed
    -- underneath it. Still open, and honestly so.
    when c.latest_verdict = 'still_works' then 'stale'
    -- Never confirmed by anyone, and written against a tool used over a year ago.
    when t.latest_tool_use < current_date - interval '12 months' then 'stale'
    else 'unverified'
  end as tombstone_status,

  -- The filled square, in one boolean, so that nothing rendering a list has to re-derive
  -- it from the string above and get the comparison subtly wrong.
  --
  -- Coalesced for a sharper reason than the count above. With no confirmation the
  -- comparison is null rather than false, and null is falsy in JavaScript but renders as
  -- "unknown" in SQL and as `null` in the JSON export -- so the same practice would be
  -- open in the interface and unclassifiable in the corpus. A square is filled or it is
  -- not; there is no third state, and the type should not offer one.
  coalesce(
    c.latest_verdict = 'still_works'
    and c.latest_confirmation_at >= now() - interval '12 months',
    false
  ) as is_verified

from public.practices p

-- LATERAL rather than a grouped join, so that a practice with no tools or no confirmations
-- still produces exactly one row. An inner join would silently drop the unconfirmed
-- practices, which are the majority and the ones the open square is for.
left join lateral (
  select max(pt.used_on) as latest_tool_use
    from public.practice_tools pt
   where pt.practice_id = p.id
) t on true

left join lateral (
  select
    pc.verdict    as latest_verdict,
    pc.created_at as latest_confirmation_at,
    (select count(*)
       from public.practice_confirmations n
      where n.practice_id = p.id) as confirmation_count
  from public.practice_confirmations pc
  where pc.practice_id = p.id
  -- Most recent wins outright. id breaks a tie so the result is deterministic rather than
  -- whatever the planner returns first, which would make a tombstone flicker between two
  -- values on successive page loads.
  order by pc.created_at desc, pc.id desc
  limit 1
) c on true;

comment on view public.practice_staleness is
  'Per practice: most recent tool use, latest confirmation, and the derived tombstone. '
  'SECURITY INVOKER -- without it this view would return pending and hidden practices to '
  'anonymous callers.';

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- A SECURITY INVOKER view needs the caller to hold SELECT on the view *and* on everything
-- underneath it. Those grants are already in place from the migrations that created the
-- tables; this is the view's own.

grant select on public.practice_staleness to anon, authenticated;
