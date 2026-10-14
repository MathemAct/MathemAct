-- Schema version 2 of a report: the fields, the vocabularies, and the rules that make them
-- worth having.
--
-- Most of what is asserted here is a refusal, and that is the point of the exercise. Version 2
-- added eleven columns to public.reports and one to public.report_tools, and every one of them
-- is optional — so the only thing standing between "optional" and "unvalidated" is the set of
-- constraints below. A rating of 47, a supporting link to somebody's laptop, a career stage
-- nothing renders: each would be accepted silently by a column that was merely nullable, and
-- each would be read as data by a researcher five years from now.
--
-- Three of the assertions are about arithmetic that has already gone wrong once in this
-- project and would go wrong the same way again:
--
--   The **overload count**. `create or replace function` is not idempotent across a signature
--   change, and version 2 changed the signature of both RPCs by thirteen parameters. Two
--   private.log_activity()s stopped every content write on the site in August; 012 counts
--   these two functions for the same reason.
--
--   The **guard's freeze list**. A new column the guard does not name is a column an author
--   can still rewrite after somebody has confirmed the report. Nothing warns you, and the
--   symptom is a confirmation attesting to text nobody can read any more.
--
--   The **derived facets**. `has_prompts` and `has_transcript` are generated rather than
--   maintained, because a copy kept in step by a trigger is a copy that can be out of step.
--
-- No `set constraints all immediate` anywhere in this file, unlike 009. The at-least-one-tool
-- rule is deferred and this transaction ends in a rollback, so reports inserted here without
-- tool rows are never checked — which is what lets a constraint test be one statement instead
-- of a savepoint and a fixture.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(52);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('bbbbbbbb-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'v2author@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('bbbbbbbb-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'v2reader@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

-- ── The two axes gained values ──────────────────────────────────────────────────────
-- Area is why you were working; task type is what the tool was asked to do. `outreach` and
-- `administration` are areas the original five did not cover; `comprehension` and
-- `programming` are task types that were landing in `literature_search` and `formalisation`
-- respectively, and the second of those made the formalisation numbers overstate themselves.

select ok(
  'outreach' = any (enum_range(null::public.report_area)::text[]),
  'report_area has outreach: explaining mathematics to people outside it is neither teaching nor writing'
);

select ok(
  'administration' = any (enum_range(null::public.report_area)::text[]),
  'and administration: a grant application is not research and is not writing'
);

select ok(
  'comprehension' = any (enum_range(null::public.report_task_type)::text[]),
  'report_task_type has comprehension: "I read a paper with it" is not a literature search'
);

select ok(
  'programming' = any (enum_range(null::public.report_task_type)::text[]),
  'and programming: code that is not a formal proof was inflating formalisation'
);

select ok(
  'example_counterexample' = any (enum_range(null::public.report_task_type)::text[]),
  'and example_counterexample: a distinct mathematical goal, not reducible to computation'
);

select ok(
  'brainstorming' = any (enum_range(null::public.report_task_type)::text[]),
  'and brainstorming: free-form idea generation before a formal claim is committed to'
);

-- ── The two derived columns ─────────────────────────────────────────────────────────
-- Generated, not trigger-maintained. They exist so the freshness overlay can answer "includes
-- the prompts" without fetching up to twenty thousand characters of transcript per row, on the
-- one query in this project that a reading page is allowed to make.

select is(
  (select a.attgenerated
     from pg_attribute a
    where a.attrelid = 'public.reports'::regclass and a.attname = 'has_prompts'),
  's'::"char",
  'has_prompts is a generated column, so it cannot disagree with prompts'
);

select is(
  (select a.attgenerated
     from pg_attribute a
    where a.attrelid = 'public.reports'::regclass and a.attname = 'has_transcript'),
  's'::"char",
  'and so is has_transcript'
);

-- ── area_other, in both directions ──────────────────────────────────────────────────
-- An unqualified `other` is a row that has opted out of the axis, and an `area_other` on a
-- report whose area is `research` is a field that will never be displayed and will be read as
-- data by somebody.

select lives_ok(
  $$ insert into public.reports
       (id, author_id, title, area, area_other, task_type, aim, method, outcome,
        outcome_notes, verification, third_party_material_confirmed)
     values ('cccc0000-0000-0000-0000-000000000001',
             'bbbbbbbb-0000-0000-0000-000000000001', 'Other, said which', 'other',
             'reviewing a grant panel''s workload', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  'an area of other with a qualifier is accepted'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Other, said nothing', 'other',
             'other', 'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'an area of other with no qualifier is refused: "other" on its own says nothing'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, area_other, task_type, aim, method, outcome,
        outcome_notes, verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Research, qualified', 'research',
             'but also administration', 'other', 'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'and a qualifier on any other area is refused too, which is the direction people forget'
);

-- ── task_secondary is normalised, not refused ───────────────────────────────────────
-- A duplicated secondary task is a slip with one obvious right answer, and a submission
-- somebody spent ten minutes on should not fail on one. The cardinality cap is the only hard
-- rule, and it sees the array after the trigger has tidied it.

insert into public.reports
  (id, author_id, title, area, task_type, task_secondary, aim, method, outcome,
   outcome_notes, verification, third_party_material_confirmed)
values ('cccc0000-0000-0000-0000-000000000002',
        'bbbbbbbb-0000-0000-0000-000000000001', 'Several things at once', 'research',
        'proof_drafting',
        array['computation', 'proof_drafting', 'computation', 'comprehension']::public.report_task_type[],
        'a', 'b', 'partial', 'c', 'd', true);

select is(
  (select task_secondary::text[] from public.reports
    where id = 'cccc0000-0000-0000-0000-000000000002'),
  array['comprehension', 'computation'],
  'the primary task is stripped out, duplicates are collapsed, and what is left is sorted'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, task_secondary, aim, method, outcome,
        outcome_notes, verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Everything', 'research', 'other',
             array['computation', 'comprehension', 'translation', 'exposition']::public.report_task_type[],
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'four distinct secondary tasks is refused: past three it is the whole list, which says nothing'
);

select is(
  (select task_secondary::text[] from public.reports
    where id = 'cccc0000-0000-0000-0000-000000000001'),
  '{}'::text[],
  'a report that named none has an empty array rather than a null, so nothing has to coalesce'
);

-- ── The small closed vocabularies ───────────────────────────────────────────────────
-- Text with a CHECK rather than an enum, because each is a short list nothing joins against.
-- The CHECK is what makes that a vocabulary rather than a free-text field with a convention.

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, career_stage, aim, method, outcome,
        outcome_notes, verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Bad stage', 'research', 'other',
             'emeritus', 'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'a career stage outside the list is refused, so no page has to render a value it has no words for'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, generalises, aim, method, outcome,
        outcome_notes, verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Bad reach', 'research', 'other',
             'universally', 'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'and so is a generalisation outside the three'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, prompts, aim, method, outcome,
        outcome_notes, verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Too many prompts', 'research',
             'other', repeat('x', 4001), 'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'prompts past the cap are refused: the field is the prompts, not the session'
);

-- ── The scales ──────────────────────────────────────────────────────────────────────
-- 0 to 10, or null. Null is the ordinary answer and means the question was not answered — or,
-- for the two conditional scales, was never asked. Never 0 for either.

select lives_ok(
  $$ insert into public.reports
       (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed,
        rating_helpfulness, time_saved,
        rating_trust_before_checking, rating_verification_effort, rating_novelty,
        rating_understanding_gained, generalises, career_stage)
     values ('cccc0000-0000-0000-0000-000000000003',
             'bbbbbbbb-0000-0000-0000-000000000001', 'Fully counted', 'learning',
             'comprehension', 'a', 'b', 'partial', 'c', 'd', true,
             0, 'few_hours', 7, 10, 2, 9, 'similar_tasks', 'doctoral') $$,
  'a report may answer every scale, including a 0, which is a finding rather than a blank'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, rating_helpfulness)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Off the scale', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', true, 11) $$,
  '23514'::text, null::text,
  'a rating above 10 is refused'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, rating_novelty)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Under the scale', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', true, -1) $$,
  '23514'::text, null::text,
  'and one below 0, which is what a "cost me time" answer would try to be without its own column'
);

-- ── The confirmation, now conditional ───────────────────────────────────────────────
-- Required when there is pasted material, meaningless when there is not. 009 asserts both
-- refusals; the permission belongs here, where a report with no tool rows is harmless.

select lives_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Nothing pasted', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', false) $$,
  'a report that pasted nothing needs no affirmation, because there is nothing to affirm'
);

-- ── Supporting links ────────────────────────────────────────────────────────────────
-- https only, no private addresses, eight at most. Nothing here says whether a link
-- resolves: that is scripts/link-check.mjs, monthly, and a constraint guessing at it would
-- refuse working URLs with brackets and commas in them.

select lives_ok(
  $$ insert into public.reports
       (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('cccc0000-0000-0000-0000-000000000004',
             'bbbbbbbb-0000-0000-0000-000000000001', 'With links', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true,
             '[{"kind":"paper","url":"https://doi.org/10.1000/xyz","label":"The preprint"},
               {"kind":"formalisation","url":"https://github.com/example/lean-proof"}]'::jsonb) $$,
  'a paper and a formalisation, one with a label and one without, are both accepted'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Nine links', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true,
             (select jsonb_agg(jsonb_build_object('kind', 'other',
                                                  'url', 'https://example.org/' || n))
                from generate_series(1, 9) as n)) $$,
  '23514'::text, null::text,
  'nine supporting links is refused: eight is already more than a reader will follow'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Odd kind', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true,
             '[{"kind":"conversation","url":"https://example.org/chat"}]'::jsonb) $$,
  '23514'::text, null::text,
  'an unknown kind is refused — and "conversation" in particular, because a share link belongs in transcript_url where it may not stand alone'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Plain http', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true,
             '[{"kind":"paper","url":"http://example.org/paper.pdf"}]'::jsonb) $$,
  '23514'::text, null::text,
  'http is refused: this audience will not click it'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Somebody''s laptop', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', true,
             '[{"kind":"code","url":"https://192.168.1.4/repo"}]'::jsonb) $$,
  '23514'::text, null::text,
  'a private address is refused: it is a link that works for exactly one reader'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'Long label', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true,
             jsonb_build_array(jsonb_build_object('kind', 'paper',
                                                  'url', 'https://doi.org/10.1000/xyz',
                                                  'label', repeat('x', 81)))) $$,
  '23514'::text, null::text,
  'a label past 80 characters is refused: it is shown instead of the URL, not instead of the report'
);

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed, "references")
     values ('bbbbbbbb-0000-0000-0000-000000000001', 'A bare string', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true,
             '["https://example.org/paper"]'::jsonb) $$,
  '23514'::text, null::text,
  'an element that is not an object is refused, so nothing downstream has to guess what a link is'
);

-- ── What a tool row says it did ─────────────────────────────────────────────────────
-- `role` is what turns two tool rows into an account, and it had to join the uniqueness key:
-- without it, one model that drafted and then checked in the same afternoon is a unique
-- violation on the second row, which is exactly the account the column was added for.

insert into public.reports
  (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
   verification, third_party_material_confirmed)
values ('cccc0000-0000-0000-0000-000000000005',
        'bbbbbbbb-0000-0000-0000-000000000001', 'One tool, two jobs', 'research',
        'proof_drafting', 'a', 'b', 'partial', 'c', 'd', true);

select lives_ok(
  $$ insert into public.report_tools (report_id, tool_name, tool_version, used_on, role)
     values ('cccc0000-0000-0000-0000-000000000005', 'Claude', 'Opus 4.5',
             current_date - 2, 'drafted the sketch'),
            ('cccc0000-0000-0000-0000-000000000005', 'Claude', 'Opus 4.5',
             current_date - 2, 'checked the proof') $$,
  'the same tool, version and day appears twice in two roles'
);

select throws_ok(
  $$ insert into public.report_tools (report_id, tool_name, tool_version, used_on, role)
     values ('cccc0000-0000-0000-0000-000000000005', 'Lean', '4.9.0', current_date - 2, null),
            ('cccc0000-0000-0000-0000-000000000005', 'Lean', '4.9.0', current_date - 2, null) $$,
  '23505'::text, null::text,
  'while two role-less rows for one tool on one day are still the duplicate they were before role existed'
);

select throws_ok(
  $$ insert into public.report_tools (report_id, tool_name, tool_version, used_on, role)
     values ('cccc0000-0000-0000-0000-000000000005', 'Isabelle', '2025',
             current_date - 1, repeat('x', 61)) $$,
  '23514'::text, null::text,
  'a role past 60 characters is refused: a few words is what the field is for'
);

select throws_ok(
  $$ insert into public.report_tools (report_id, tool_name, tool_version, used_on)
     values ('cccc0000-0000-0000-0000-000000000005', repeat('x', 81), '1', current_date - 1) $$,
  '23514'::text, null::text,
  'the tool name cap came down to 80, which no real tool name reaches'
);

select throws_ok(
  $$ insert into public.report_tools (report_id, tool_name, tool_version, used_on)
     values ('cccc0000-0000-0000-0000-000000000005', 'Magma', repeat('x', 41),
             current_date - 1) $$,
  '23514'::text, null::text,
  'and the version cap to 40: past that it is a sentence in the wrong field'
);

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Grants decide whether a column can be named at all; the policies decide which rows. A
-- missing grant and a missing policy look identical from a browser, so both are asserted.

select ok(
  has_column_privilege('authenticated', 'public.reports', 'prompts', 'INSERT'),
  'authenticated may write prompts'
);

select ok(
  has_column_privilege('authenticated', 'public.reports', 'references', 'INSERT'),
  'and the supporting links, quoted column name and all'
);

select ok(
  not has_column_privilege('authenticated', 'public.reports', 'schema_version', 'INSERT'),
  'and not schema_version: which version of the standard a row answers is the schema''s statement, not the author''s'
);

select ok(
  not has_column_privilege('anon', 'public.reports', 'prompts', 'INSERT'),
  'anon writes nothing here, as before'
);

-- Postgres grants EXECUTE to PUBLIC on every new function, so each one needs an explicit
-- REVOKE. migrate.yml asserts this in production; here it is asserted before it ships.
select ok(
  not has_function_privilege('authenticated', 'private.normalise_report_tasks()', 'EXECUTE'),
  'private.normalise_report_tasks is not reachable by a browser role'
);

select ok(
  not has_function_privilege('authenticated', 'private.check_report_references()', 'EXECUTE'),
  'nor is private.check_report_references'
);

-- ── The guard's freeze list ─────────────────────────────────────────────────────────
-- A hidden report is editable by its author — that is what a hide is for — and the guard is
-- what decides which *columns* an editable report exposes. Every version 2 content column had
-- to join the freeze list, and a column the guard does not name is a column an author can
-- still rewrite after somebody has confirmed the report.
--
-- Run as `authenticated` throughout. The guard is SECURITY INVOKER, so as the owner it returns
-- early and asserts nothing: a test of a guard that runs as the owner is a test that passes
-- whether or not the guard works.

insert into public.reports
  (id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
   verification, third_party_material_confirmed, prompts)
values ('cccc0000-0000-0000-0000-000000000006',
        'bbbbbbbb-0000-0000-0000-000000000001', 'hidden', 'A hidden report', 'research',
        'other', 'a', 'b', 'worked', 'c', 'd', true, 'the original prompt');

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbbbbbb-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports set prompts = 'the corrected prompt'
 where id = 'cccc0000-0000-0000-0000-000000000006';

reset role;

select is(
  (select prompts from public.reports where id = 'cccc0000-0000-0000-0000-000000000006'),
  'the corrected prompt',
  'an author may correct the prompts on a hidden report: revising is their half of the exchange'
);

-- `schema_version` is refused by the grant rather than reverted by the guard, and those are
-- different observable behaviours: a column with no UPDATE grant raises 42501, a column the
-- guard reverts succeeds having changed nothing. The grant is the one that fires first, so it
-- is the one asserted.
select ok(
  not has_column_privilege('authenticated', 'public.reports', 'schema_version', 'UPDATE'),
  'schema_version cannot be named in an update at all, so the guard never has to revert it'
);

-- The freeze itself, and the route to it is the one that makes the guard necessary rather
-- than decorative. `reports_soft_delete_own` lets an author delete their own report *whatever*
-- its status, and permissive policies are OR'd — so an author can reach a frozen report with
-- an UPDATE that the editable policy would refuse, by making the same statement a deletion.
-- What stops the rest of the statement is the guard and nothing else.

insert into public.report_confirmations (report_id, user_id, verdict)
values ('cccc0000-0000-0000-0000-000000000002',
        'bbbbbbbb-0000-0000-0000-000000000002', 'still_works');

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbbbbbb-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports
   set deleted_at         = now(),
       deleted_by         = 'bbbbbbbb-0000-0000-0000-000000000001',
       prompts            = 'sneaked in after the fact',
       task_secondary     = array['translation']::public.report_task_type[],
       rating_helpfulness = 10
 where id = 'cccc0000-0000-0000-0000-000000000002';

reset role;

select is(
  (select prompts from public.reports where id = 'cccc0000-0000-0000-0000-000000000002'),
  null::text,
  'prompts on an answered report are frozen: a confirmation attests to a version'
);

select is(
  (select task_secondary::text[] from public.reports
    where id = 'cccc0000-0000-0000-0000-000000000002'),
  array['comprehension', 'computation'],
  'and so are the secondary task types, which is what the corpus is grouped by'
);

select is(
  (select rating_helpfulness from public.reports
    where id = 'cccc0000-0000-0000-0000-000000000002'),
  null::smallint,
  'and so is every scale: a rating added after the fact is a claim about a session nobody saw'
);

select ok(
  (select deleted_at is not null from public.reports
    where id = 'cccc0000-0000-0000-0000-000000000002'),
  'while the deletion the policy actually permits went through, which is what makes the rest a real attempt'
);

-- ── Through the RPC ─────────────────────────────────────────────────────────────────
-- The form's only entry point. Everything above is reachable another way; this is the path a
-- browser takes, and it is SECURITY INVOKER so every policy and trigger above still applies.

-- INSERT on public.reports is granted per column, so a column added by a later migration
-- arrives with no privilege and a column dropped and re-added loses the one it had. Both
-- happened here: was_published was re-added as text by 20260820120000 and time_saved was
-- new in 20260820130000. The failure is worth an assertion of its own because of how it
-- presents -- submit_report dies with "permission denied for table reports" and every
-- count below it reads as a policy that stopped matching.
select ok(
  has_column_privilege('authenticated', 'public.reports', 'was_published', 'INSERT')
    and has_column_privilege('authenticated', 'public.reports', 'time_saved', 'INSERT')
    and has_column_privilege('authenticated', 'public.reports', 'was_published', 'UPDATE')
    and has_column_privilege('authenticated', 'public.reports', 'time_saved', 'UPDATE'),
  'the columns this schema version replaced carry their own column grants, which a drop takes with it'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}';

select lives_ok(
  $$ select public.submit_report(
       'Draft a lemma and check it', 'research', 'proof_drafting',
       '[{"name":"Claude","version":"Opus 4.5","used_on":"2026-08-18","role":"drafted the sketch"},
         {"name":"Lean","version":"4.9.0","used_on":"2026-08-19","role":"checked the proof"}]'::jsonb,
       'Find out whether a lemma I believed was true.',
       'Asked for a sketch, then formalised it.',
       'partial', 'The sketch had a gap in the base case.',
       'Lean accepted the final proof.',
       true,
       'user: is this lemma true as stated?', null,
       'I would state the hypotheses in full first.',
       120, null, null, 7,
       array['math.NT'],
       null,
       array['proof_checking', 'formalisation', 'proof_drafting'],
       'postdoctoral',
       'Let A be a finite subset of Z with |A+A| <= 3|A|. Is A contained in a short AP?',
       '[{"kind":"formalisation","url":"https://github.com/example/lemma","label":"The Lean file"}]'::jsonb,
       8, 'few_hours', 4, 6, 9, null,
       'similar_tasks'
     ) $$,
  'a version 2 submission goes through in one call, with roles, prompts, links and scales'
);

reset role;

select is(
  (select task_secondary::text[] from public.reports
    where title = 'Draft a lemma and check it'),
  array['proof_checking', 'formalisation'],
  'the RPC normalises the secondary tasks too: the primary is stripped and the rest sorted'
);

select is(
  (select rating_novelty from public.reports where title = 'Draft a lemma and check it'),
  9::smallint,
  'the scales are stored as given, including the conditional one this area makes applicable'
);

select is(
  (select count(*)::int from public.report_tools t
     join public.reports p on p.id = t.report_id
    where p.title = 'Draft a lemma and check it' and t.role is not null),
  2,
  'and both tool rows carry what that tool did'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}';

-- Refused by the function with a sentence rather than by a constraint with a name. Seven tool
-- rows stopped describing a session some time before the seventh.
select throws_ok(
  $$ select public.submit_report(
       'Seven tools', 'research', 'other',
       (select jsonb_agg(jsonb_build_object('name', 'Tool ' || n, 'version', '1',
                                            'used_on', '2026-08-01'))
          from generate_series(1, 7) as n),
       'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'seven tools is refused by the RPC, in a sentence about the form rather than about a constraint'
);

select throws_ok(
  $$ select public.submit_report(
       'Nine links', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', true,
       null, null, null, null, null, null, null, '{}'::text[],
       null, '{}'::text[], null, null,
       (select jsonb_agg(jsonb_build_object('kind', 'other',
                                            'url', 'https://example.org/' || n))
          from generate_series(1, 9) as n)) $$,
  '23514'::text, null::text,
  'and so is a ninth supporting link, refused by the function before the constraint gets a chance to name itself'
);

reset role;

select * from finish();

rollback;
