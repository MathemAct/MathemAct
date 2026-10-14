-- public.submit_report() — the one entry point the submission form uses.
--
-- The property under test is not "it inserts rows". It is that wrapping three inserts in a
-- function bought a transaction and nothing else: every policy, grant, constraint and
-- trigger that guards the tables directly must still guard them through here. A function
-- that quietly relaxed one of them would look identical to this one from the outside, and
-- would be the largest hole in the schema.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(19);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('99999999-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'submitter@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('99999999-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'notyet@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('99999999-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'excluded@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id <> '99999999-0000-0000-0000-000000000002';

update public.profiles set is_banned = true
 where id = '99999999-0000-0000-0000-000000000003';

-- ── Who may call it ─────────────────────────────────────────────────────────────────

-- Spelled out in full, and the length of it is the point: this is the assertion that fails
-- when somebody adds a parameter with `create or replace` instead of dropping and recreating,
-- which creates a *second* function rather than changing this one. That mistake stopped every
-- content write on the site once already; see 20260819090000.
select ok(
  not has_function_privilege('anon', 'public.submit_report(text, public.report_area, '
    'public.report_task_type, jsonb, text, text, public.report_outcome, text, text, '
    'boolean, text, text, text, integer, text, boolean, integer, text[], '
    'text, text[], text, text, jsonb, integer, text, integer, integer, '
    'integer, integer, text, boolean, text)', 'EXECUTE'),
  'anon cannot execute submit_report'
);

select ok(
  has_function_privilege('authenticated', 'public.submit_report(text, public.report_area, '
    'public.report_task_type, jsonb, text, text, public.report_outcome, text, text, '
    'boolean, text, text, text, integer, text, boolean, integer, text[], '
    'text, text[], text, text, jsonb, integer, text, integer, integer, '
    'integer, integer, text, boolean, text)', 'EXECUTE'),
  'authenticated can'
);

-- There is exactly one of each. Named without an argument list on purpose: the count is what
-- catches the overload, and a count of two here is the shape of the outage referred to above.
select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('submit_report', 'resubmit_report')),
  2,
  'one submit_report and one resubmit_report, not an overload of either'
);

-- SECURITY INVOKER is the whole safety argument. As DEFINER this function would run as its
-- owner and bypass every policy underneath it while looking exactly the same.
select is(
  (select p.prosecdef
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'submit_report'),
  false,
  'submit_report is SECURITY INVOKER, so the policies underneath it still apply'
);

-- ── The happy path ──────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"99999999-0000-0000-0000-000000000001","role":"authenticated"}';

select lives_ok(
  $$ select public.submit_report(
       'Check a lemma with a proof assistant',
       'research', 'proof_checking',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"},
         {"name":"GPT-5","version":"2026-05","used_on":"2026-08-02"}]'::jsonb,
       'Confirm a lemma I could not see a gap in.',
       'Stated it in Lean and closed the goals one at a time.',
       'partial', 'It found a missing hypothesis I had assumed.',
       'Lean accepted the final proof, and I re-derived the counterexample by hand.',
       true,
       'user: is this lemma true as stated?',
       'https://example.org/transcript',
       'I would state the hypotheses first next time.',
       95, 'yes', true, 8,
       array['math.NT', 'math.LO']
     ) $$,
  'a confirmed member can submit a report, its tools and its tags in one call'
);

reset role;

select is(
  (select count(*)::int from public.reports),
  1,
  'the report is there'
);

select is(
  (select status::text from public.reports limit 1),
  'published'::text,
  'and it is in the corpus: submitting is publishing, and nothing waits for a moderator'
);

select is(
  (select author_id from public.reports limit 1),
  '99999999-0000-0000-0000-000000000001'::uuid,
  'the author is the caller, taken from auth.uid() rather than from a parameter'
);

select is(
  (select count(*)::int from public.report_tools),
  2,
  'both tools are recorded'
);

select is(
  (select count(*)::int from public.report_tags),
  2,
  'and both tags, matched by code so the client never handles a uuid'
);

-- ── What it must still refuse ───────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"99999999-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_report(
       'From an unconfirmed account', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'an unconfirmed account is still refused, by the policy rather than by the function'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"99999999-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_report(
       'From a banned account', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'and so is a banned one'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"99999999-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_report(
       'No tools', 'research', 'other', '[]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'a submission recording no tool is refused with a sentence, not a constraint name'
);

select throws_ok(
  $$ select public.submit_report(
       'No verification', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', '   ', true) $$,
  '23514'::text, null::text,
  'the verification field is still required through this path'
);

-- The affirmation is required when something was pasted and meaningless when nothing was, so
-- this case passes an excerpt. Before 20260820100000 it was required unconditionally, which
-- read as the stronger rule and was the weaker one.
select throws_ok(
  $$ select public.submit_report(
       'Unconfirmed material', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', false,
       'user: is this lemma true?') $$,
  '23514'::text, null::text,
  'and so is the third-party material confirmation, when there is a transcript to affirm about'
);

-- A share link is supplementary and never the only record: links expire, are revoked, and
-- may breach provider terms, while the excerpt is ours and is what the export carries.
select throws_ok(
  $$ select public.submit_report(
       'A link and nothing else', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', true,
       null, 'https://example.org/shared') $$,
  '23514'::text, null::text,
  'a transcript link with no excerpt is refused: the link is never the only record'
);

-- The asymmetry is the rule. An excerpt with no link is ordinary.
select lives_ok(
  $$ select public.submit_report(
       'An excerpt and no link', 'research', 'other',
       '[{"name":"Lean","version":"4.9.0","used_on":"2026-08-01"}]'::jsonb,
       'a', 'b', 'worked', 'c', 'd', true,
       'user: is this true?') $$,
  'while an excerpt with no link is perfectly ordinary'
);

reset role;

-- ── All or nothing ──────────────────────────────────────────────────────────────────
-- The reason this is a function rather than three requests. A tool row that fails must
-- take the report with it, or the corpus accumulates accounts with no date of use --
-- which the staleness view would render as permanently current.

set local role authenticated;
set local request.jwt.claims to '{"sub":"99999999-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_report(
       'A tool used tomorrow', 'research', 'other',
       ('[{"name":"Lean","version":"4.9.0","used_on":"'
         || to_char(current_date + 1, 'YYYY-MM-DD') || '"}]')::jsonb,
       'a', 'b', 'worked', 'c', 'd', true) $$,
  '23514'::text, null::text,
  'a bad tool row fails the whole submission'
);

reset role;

select is(
  (select count(*)::int from public.reports),
  2,
  'and leaves no half-written report behind'
);

select * from finish();

rollback;
