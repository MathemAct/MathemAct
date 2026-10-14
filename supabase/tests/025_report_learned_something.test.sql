-- Schema version 3 of a report: "Did you learn something new?" and the note that elaborates it.
--
-- Two optional columns, so the assertions are about what keeps "optional" from meaning
-- "unvalidated", and about the three things that go wrong silently when a column is added to
-- public.reports:
--
--   The **grant**. INSERT and UPDATE here are per column, so a new column arrives with no
--   privilege and submit_report dies with "permission denied", which reads as a policy.
--
--   The **freeze list**. A column the guard does not name can be rewritten after somebody has
--   confirmed the report.
--
--   The **overload count**. 012 counts submit_report and resubmit_report; this file asserts the
--   new parameters arrived by drop-and-recreate rather than by a second function.
--
-- Null is asserted as a state of its own: unanswered is not "no".

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(15);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('dddddddd-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'learner@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('dddddddd-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'confirmer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

-- ── The columns and the version ─────────────────────────────────────────────────────

select ok(
  has_column_privilege('authenticated', 'public.reports', 'learned_something', 'INSERT')
    and has_column_privilege('authenticated', 'public.reports', 'learned_notes', 'INSERT')
    and has_column_privilege('authenticated', 'public.reports', 'learned_something', 'UPDATE')
    and has_column_privilege('authenticated', 'public.reports', 'learned_notes', 'UPDATE'),
  'both columns carry their own insert and update grants'
);

select ok(
  not has_column_privilege('anon', 'public.reports', 'learned_something', 'INSERT')
    and not has_column_privilege('anon', 'public.reports', 'learned_notes', 'UPDATE'),
  'anon writes neither'
);

select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('submit_report', 'resubmit_report')),
  2,
  'still one submit_report and one resubmit_report: the new parameters did not create an overload'
);

select is(
  (select pg_get_expr(d.adbin, d.adrelid)
     from pg_attrdef d
     join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where d.adrelid = 'public.reports'::regclass and a.attname = 'schema_version'),
  '3',
  'a new report is written against schema version 3'
);

-- ── What the columns will and will not hold ─────────────────────────────────────────

select lives_ok(
  $$ insert into public.reports
       (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, learned_something, learned_notes)
     values ('eeee0000-0000-0000-0000-000000000001',
             'dddddddd-0000-0000-0000-000000000001', 'Learned from a failure', 'research',
             'other', 'a', 'b', 'failed', 'c', 'd', false, true,
             'The counterexample showed my hypothesis was too strong.') $$,
  'a failed attempt may say it taught something, with a note'
);

select lives_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, learned_something)
     values ('dddddddd-0000-0000-0000-000000000001', 'Learned nothing', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', false, false) $$,
  'a "no" with no note is accepted: an answer needs no elaboration'
);

select is(
  (select learned_something from public.reports
    where title = 'Learned nothing'),
  false,
  'and is stored as false'
);

select lives_ok(
  $$ insert into public.reports
       (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('eeee0000-0000-0000-0000-000000000002',
             'dddddddd-0000-0000-0000-000000000001', 'Not asked', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', false) $$,
  'a report may leave the section alone'
);

select is(
  (select learned_something from public.reports
    where id = 'eeee0000-0000-0000-0000-000000000002'),
  null::boolean,
  'and the answer is null, not false: unanswered is not "no"'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, learned_notes)
     values ('dddddddd-0000-0000-0000-000000000001', 'Note without answer', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', false, 'I think I learned something.') $$,
  '23514'::text, null::text,
  'a note with no answer is refused: it would elaborate on nothing'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, learned_something, learned_notes)
     values ('dddddddd-0000-0000-0000-000000000001', 'Long note', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', false, true, repeat('x', 1001)) $$,
  '23514'::text, null::text,
  'a note past 1000 characters is refused'
);

-- ── The guard's freeze list ─────────────────────────────────────────────────────────
-- Run as `authenticated`: the guard is SECURITY INVOKER and returns early for the owner, so a
-- test run as the owner passes whether or not the guard works. The route to a frozen report is
-- a soft delete, which `reports_soft_delete_own` permits whatever the status, so the rest of
-- that statement is stopped by the guard and by nothing else.

insert into public.report_confirmations (report_id, user_id, verdict)
values ('eeee0000-0000-0000-0000-000000000001',
        'dddddddd-0000-0000-0000-000000000002', 'still_fails');

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports
   set deleted_at        = now(),
       deleted_by        = 'dddddddd-0000-0000-0000-000000000001',
       learned_something = false,
       learned_notes     = 'rewritten after somebody confirmed it'
 where id = 'eeee0000-0000-0000-0000-000000000001';

reset role;

select is(
  (select learned_something from public.reports
    where id = 'eeee0000-0000-0000-0000-000000000001'),
  true,
  'the answer on a report somebody has confirmed is frozen'
);

select is(
  (select learned_notes from public.reports
    where id = 'eeee0000-0000-0000-0000-000000000001'),
  'The counterexample showed my hypothesis was too strong.',
  'and so is the note'
);

-- ── Through the RPC ─────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000002","role":"authenticated"}';

select lives_ok(
  $$ select public.submit_report(
       'Learned through the RPC', 'learning', 'comprehension',
       '[{"name":"Claude","version":"Opus 4.5","used_on":"2026-08-18"}]'::jsonb,
       'Understand a lemma.', 'Asked for an explanation.', 'worked',
       'It filled in the omitted steps.', 'Checked each step by hand.', false,
       p_learned_something => true,
       p_learned_notes => '  About the tool: it is reliable on routine estimates.  '
     ) $$,
  'the form''s entry point takes the answer and the note'
);

select throws_ok(
  $$ select public.submit_report(
       'Note only', 'learning', 'comprehension',
       '[{"name":"Claude","version":"Opus 4.5","used_on":"2026-08-18"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', false,
       p_learned_notes => 'A note with nothing to elaborate.'
     ) $$,
  '23514'::text, null::text,
  'and refuses a note with no answer, in a sentence about the form'
);

reset role;

select * from finish();

rollback;
