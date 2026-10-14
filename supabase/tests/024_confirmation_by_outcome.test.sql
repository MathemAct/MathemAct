-- Two questions, not one: the confirmation verdict has to answer the question its report
-- asks.
--
-- Until 2026-08-23 the confirmation control asked "Does this still work?" of every report,
-- including the ones whose outcome was 'failed'. Every answer available on such a report was
-- a claim its author had not made, and somebody who rechecked a failure and found it still
-- failing -- which is exactly the work this feature collects -- had no way to say so.
--
-- The pairing is a cross-table rule (the verdict is on one table, the outcome on another),
-- so it cannot be a CHECK constraint. It is two BEFORE triggers instead, and the reason
-- there are two is that there are two ways to break the pairing:
--
--   1. Filing a verdict that does not match the report's outcome.
--   2. Moving the report's outcome out from under a verdict already filed.
--
-- The second half of this file is about the second one, and about the trigger ordering that
-- keeps it from breaking the freeze rule it sits next to. That ordering is the part of this
-- change most likely to be undone by accident, because the thing that protects it is a
-- trigger's *name*.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(15);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('99999999-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'author@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('99999999-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'checker@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

-- Four published reports: two that worked, one that partly worked, one that did not. No
-- tools on any of them, and no `set constraints all immediate` anywhere in this file — the
-- at-least-one-tool check is deferred to commit, this transaction rolls back, and nothing
-- here is about tools. Same arrangement as 021.
insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
) values
  ('aaaa1111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001',
   'published', 'It worked', 'research', 'other', 'a', 'b', 'worked', 'c', 'd', true),
  ('aaaa1111-0000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000001',
   'published', 'It did not work', 'research', 'other', 'a', 'b', 'failed', 'c', 'd', true),
  ('aaaa1111-0000-0000-0000-000000000003', '99999999-0000-0000-0000-000000000001',
   'published', 'It partly worked', 'research', 'other', 'a', 'b', 'partial', 'c', 'd', true),
  ('aaaa1111-0000-0000-0000-000000000004', '99999999-0000-0000-0000-000000000001',
   'published', 'Another one that worked', 'research', 'other', 'a', 'b', 'worked', 'c', 'd', true);

-- ── Guard 1: the verdict answers the question the outcome asks ───────────────────────
-- Asserted as the owner rather than through a browser role on purpose. The guard is a
-- constraint rather than a privilege check and exempts nobody, so the owner is the harshest
-- caller to assert it from: if it fires here it fires everywhere.

select lives_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('aaaa1111-0000-0000-0000-000000000001',
             '99999999-0000-0000-0000-000000000002', 'still_works') $$,
  'a report that worked takes "it still works"'
);

select throws_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('aaaa1111-0000-0000-0000-000000000004',
             '99999999-0000-0000-0000-000000000002', 'still_fails') $$,
  '23514'::text, null::text,
  'but not "it still does not work", which answers a question it does not ask'
);

select lives_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('aaaa1111-0000-0000-0000-000000000002',
             '99999999-0000-0000-0000-000000000002', 'still_fails') $$,
  'a report that did not work takes "it still does not work" -- the answer that was unsayable before'
);

select throws_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('aaaa1111-0000-0000-0000-000000000002',
             '99999999-0000-0000-0000-000000000001', 'no_longer_works') $$,
  '23514'::text, null::text,
  'and refuses "it no longer works" on a report that never worked'
);

-- 'partial' is on the success side of the axis, not a third case. A partial success that
-- stopped working has stopped working, and there is no third pair of words for it.
select lives_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('aaaa1111-0000-0000-0000-000000000003',
             '99999999-0000-0000-0000-000000000002', 'no_longer_works') $$,
  'a partial success is asked the same question as a full one'
);

-- The trigger is on UPDATE as well, which is not decoration: saveConfirmation() upserts, so
-- changing your mind is an UPDATE, and a guard that only fired on INSERT would let the
-- second thought say what the first could not.
select throws_ok(
  $$ update public.report_confirmations
        set verdict = 'now_works'
      where report_id = 'aaaa1111-0000-0000-0000-000000000001' $$,
  '23514'::text, null::text,
  'and changing your mind cannot cross to the other pair either'
);

-- ── Guard 2: the outcome cannot move out from under a verdict ────────────────────────

select throws_ok(
  $$ update public.reports set outcome = 'failed'
      where id = 'aaaa1111-0000-0000-0000-000000000001' $$,
  '23514'::text, null::text,
  'the outcome cannot cross to the other side while a verdict answering this side stands'
);

-- The narrow move that is allowed, and it matters: correcting "it worked" to "it partly
-- worked" is the commonest honest correction an author makes, and both take the same two
-- answers, so nothing is orphaned by it.
select lives_ok(
  $$ update public.reports set outcome = 'partial'
      where id = 'aaaa1111-0000-0000-0000-000000000001' $$,
  'but a move within one side is left alone, because the answers on offer do not change'
);

select is(
  (select outcome::text from public.reports
    where id = 'aaaa1111-0000-0000-0000-000000000001'),
  'partial',
  'and it actually went through, rather than being quietly reverted'
);

-- A report nobody has confirmed is not the guard's business at all.
select lives_ok(
  $$ update public.reports set outcome = 'failed'
      where id = 'aaaa1111-0000-0000-0000-000000000004' $$,
  'an unconfirmed report can have its outcome corrected freely'
);

-- ── The trigger ordering, which is the fragile part ──────────────────────────────────
-- BEFORE ROW triggers fire in alphabetical order by trigger name, and a WHEN clause is
-- evaluated against NEW as earlier triggers have already modified it.
--
-- private.protect_report_columns() runs as `reports_protect_columns` and, on a report
-- somebody *else* has answered, reverts the outcome and lets the statement succeed having
-- changed nothing. `reports_verdicts_match_outcome` sorts after it, so the revert lands
-- first, the WHEN clause is then false, and the raise never happens.
--
-- Rename that trigger to anything sorting before 'p' and this assertion flips from "the
-- statement succeeded and changed nothing" to "the statement threw" -- which would abort
-- the legitimate half of any statement an author sent alongside the sneak, including the
-- deletion 021 relies on going through.

-- Report 2 has a confirmation from somebody other than its author, so answered_at is set
-- and the whole report is frozen.
select isnt(
  (select answered_at from public.reports
    where id = 'aaaa1111-0000-0000-0000-000000000002'),
  null::timestamptz,
  'a confirmation by somebody other than the author freezes the report'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"99999999-0000-0000-0000-000000000001","role":"authenticated"}';

-- The deletion is what makes this a real attempt rather than a permission error. Both
-- author UPDATE policies on a frozen report are permissive and OR'd: the editable one
-- refuses it outright, and `reports_soft_delete_own` permits it only if the row ends up
-- deleted. So an UPDATE that merely changed the outcome would come back 42501 and would
-- assert nothing about trigger ordering. This is the same shape as the attempt in 021.
select lives_ok(
  $$ update public.reports
        set deleted_at = now(),
            deleted_by = '99999999-0000-0000-0000-000000000001',
            outcome    = 'worked'
      where id = 'aaaa1111-0000-0000-0000-000000000002' $$,
  'an author editing a frozen report gets the silent revert, not an exception'
);

reset role;

select is(
  (select outcome::text from public.reports
    where id = 'aaaa1111-0000-0000-0000-000000000002'),
  'failed',
  'and the outcome did not move, which is the freeze doing its job rather than this guard'
);

select ok(
  (select deleted_at is not null from public.reports
    where id = 'aaaa1111-0000-0000-0000-000000000002'),
  'while the deletion the policy does permit went through, so the statement really ran'
);

-- ── Exposure ────────────────────────────────────────────────────────────────────────
-- Postgres grants EXECUTE to PUBLIC on every new function. A trigger fires without a
-- privilege check on its own function, so revoking costs nothing and leaving it granted
-- would put two guards on the browser's API surface.

select ok(
  not has_function_privilege('authenticated', 'private.check_confirmation_verdict()', 'EXECUTE')
    and not has_function_privilege('anon', 'private.check_confirmation_verdict()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'private.check_outcome_matches_confirmations()', 'EXECUTE')
    and not has_function_privilege('anon', 'private.check_outcome_matches_confirmations()', 'EXECUTE'),
  'neither guard is executable by a browser role'
);

select * from finish();

rollback;
