-- Proposing a claim: the position that is required, the tags, the source, and the freeze.
--
-- The assertion this file exists for is the one about the freeze, and it is the one that would
-- have shipped broken. Requiring the proposer to answer their own claim means **a rating always
-- exists from the moment a claim does** — so every rule that was written as "once anybody has
-- rated it" silently became "always", and two of them would have taken a feature with them:
-- the wording freeze would have engaged on creation, and the tag policies would have refused
-- the tags `public.submit_claim()` inserts three lines after the rating. Neither migration
-- reads as wrong on its own.
--
-- So: the author can still correct their claim after answering it themselves, somebody else
-- answering closes that, and the tags go in. Those three are the point of this file.
--
-- Everything else is the ordinary shape: the position is required, "no opinion" satisfies the
-- requirement and is stored as NULL on a real row, the two sources are mutually exclusive, and a
-- banned or unconfirmed account is refused by the policies the function runs under rather than
-- by the function.
--
-- Fixtures are created as the table owner, which the guards trust. Every assertion runs under
-- `set local role`, because what is being tested is what a browser can do — and here that matters
-- more than usual: `public.submit_claim()` is SECURITY INVOKER precisely so that the policies
-- decide, and running it as the owner would test nothing about authorisation.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(26);

-- ── People ──────────────────────────────────────────────────────────────────────────
-- auth.users has a partial unique index on email, so no two fixtures may share one.

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('f1111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'proposer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('f1111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answerer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('f1111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'declines@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('f1111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'suspended@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('f1111111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'unconfirmed-proposer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id in ('f1111111-0000-0000-0000-000000000001',
              'f1111111-0000-0000-0000-000000000002',
              'f1111111-0000-0000-0000-000000000003',
              'f1111111-0000-0000-0000-000000000004');

update public.profiles set is_banned = true
 where id = 'f1111111-0000-0000-0000-000000000004';

-- Something for the source picker to point at.
insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
) values
  ('f2222222-0000-0000-0000-000000000001', 'f1111111-0000-0000-0000-000000000001',
   'published', 'The report that prompted a claim', 'research', 'proof_checking',
   'Confirm a lemma.', 'Stated it in Lean.', 'worked', 'It closed.', 'Lean accepted it.', true);

-- ── A position is required ──────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_claim(
       'A proof assistant should be required for computer-assisted case analysis.',
       'research') $$,
  '23514'::text, null::text,
  'proposing without a position is refused: somebody unwilling to say where they stand is not setting the question'
);

select throws_ok(
  $$ select public.submit_claim(
       'A claim with a score and no opinion at once.', 'research', 7, true) $$,
  '23514'::text, null::text,
  'and a score together with "no opinion" is refused rather than one of them silently winning'
);

select is_empty(
  $$ select id from public.claims $$,
  'and neither attempt left a claim behind: the check runs before anything is written'
);

-- ── The ordinary case ───────────────────────────────────────────────────────────────

select lives_ok(
  $$ select public.submit_claim(
       'A proof assistant should be required for computer-assisted case analysis.',
       'research',
       6,
       false,
       'Case analysis by hand is where the errors are.',
       array['math.LO', 'math.NT'],
       null,
       'f2222222-0000-0000-0000-000000000001') $$,
  'a claim, a position, reasoning, tags and a source go in together'
);

reset role;

select is(
  (select count(*)::int from public.claims),
  1,
  'one claim'
);

-- The point of the function: the two writes are one transaction, so the distribution is never
-- empty on a claim somebody proposed.
select is(
  (select score from public.ratings r
     join public.claims q on q.id = r.claim_id
    where r.user_id = 'f1111111-0000-0000-0000-000000000001'),
  6::smallint,
  'the proposer''s own position is the first entry in the distribution'
);

select is(
  (select count(*)::int from public.claim_tags dt
     join public.claims q on q.id = dt.claim_id),
  2,
  'both tags attached — the policy tests for a rating by somebody *else*, so the proposer''s own does not block them'
);

select is(
  (select source_report_id from public.claims),
  'f2222222-0000-0000-0000-000000000001'::uuid,
  'and the source points at the report it came from'
);

-- ── The freeze, which is what this file is really about ─────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.claims
   set statement = 'A proof assistant should be required for any computer-assisted case analysis.'
 where author_id = 'f1111111-0000-0000-0000-000000000001';

reset role;

-- `alike()` and not `like()`. pgTAP has no `like()` — the name would collide with the SQL
-- LIKE operator — so it offers `alike`/`ialike` for patterns and `matches`/`imatches` for
-- regexes. Calling the wrong one aborts the transaction, which takes every assertion after it
-- with it: this file reported "Bad plan: you planned 25 tests but ran 8", and the seventeen it
-- skipped were fine.
select alike(
  (select statement from public.claims),
  '%for any computer-assisted%',
  'the author can still correct the wording after answering it themselves: their own answer is not an answer'
);

-- Somebody else answers, and that closes it.
set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000002","role":"authenticated"}';

insert into public.ratings (claim_id, user_id, score)
select id, 'f1111111-0000-0000-0000-000000000002', 2 from public.claims;

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000001","role":"authenticated"}';

-- Reverted rather than refused, which is the documented behaviour of this guard: a column with
-- no UPDATE grant raises, a column a guard reverts succeeds having changed nothing.
update public.claims set statement = 'Rewritten after somebody agreed to the other wording.'
 where author_id = 'f1111111-0000-0000-0000-000000000001';

reset role;

select alike(
  (select statement from public.claims),
  '%for any computer-assisted%',
  'and once somebody else has answered, the wording is frozen — silently reverted, not refused'
);

-- The tags freeze on the same condition.
set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ insert into public.claim_tags (claim_id, tag_id)
     select q.id, t.id from public.claims q, public.tags t where t.code = 'math.AG' $$,
  '42501'::text, null::text,
  'and so are the tags: a tag is part of what the claim was taken to be about'
);

reset role;

-- ── "No opinion" is a position ──────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.submit_claim(
       'Formalising a paper should be expected before submission.',
       'research', null, true) $$,
  'somebody who declines to put a number on it can still propose: the off-scale answer satisfies the requirement'
);

reset role;

select is(
  (select r.score from public.ratings r
    where r.user_id = 'f1111111-0000-0000-0000-000000000003'),
  null::smallint,
  'and it is stored as NULL on a real row, which is the off-scale answer rather than an absence'
);

select is(
  (select count(*)::int from public.ratings r
    where r.user_id = 'f1111111-0000-0000-0000-000000000003'),
  1,
  'a real row, not no row: they were asked and they answered'
);

-- ── The source ──────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_claim('A claim with two sources at once.', 'research', 5, false,
       null, '{}', 'https://example.org/a', 'f2222222-0000-0000-0000-000000000001') $$,
  '23514'::text, null::text,
  'two sources is refused: two answers to "what prompted this" is not an answer'
);

select throws_ok(
  $$ select public.submit_claim('A claim sourced from a private address.', 'research', 5, false,
       null, '{}', 'https://192.168.0.4/notes') $$,
  '23514'::text, null::text,
  'a private address is refused, on the same rule as a report''s supporting links'
);

select throws_ok(
  $$ select public.submit_claim('A claim sourced over plain http.', 'research', 5, false,
       null, '{}', 'http://example.org/a') $$,
  '23514'::text, null::text,
  'and so is anything that is not https'
);

select lives_ok(
  $$ select public.submit_claim('A claim with a link that is fine.', 'research', 5, false,
       null, '{}', '  https://example.org/a  ') $$,
  'a well-formed link is accepted, whitespace and all'
);

reset role;

select is(
  (select source_url from public.claims
    where statement = 'A claim with a link that is fine.'),
  'https://example.org/a',
  'and it is stored trimmed, so no consumer has to trim it'
);

-- ── The reasoning is capped at 500 ──────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_claim('A claim whose reasoning runs long.', 'research', 5, false,
       repeat('x', 501)) $$,
  '23514'::text, null::text,
  'the reasoning is capped at 500: the cap is what stops an opening post becoming an essay'
);

select lives_ok(
  $$ select public.submit_claim('A claim whose reasoning is exactly at the cap.', 'research',
       5, false, repeat('y', 500)) $$,
  'and 500 exactly is accepted'
);

reset role;

-- ── Who may propose ─────────────────────────────────────────────────────────────────
-- Refused by the policies the function runs under, not by the function. SECURITY INVOKER is what
-- makes that true, and a DEFINER version would have had to restate both conditions.

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_claim('A claim posted after the ban.', 'research', 5, false) $$,
  '42501'::text, null::text,
  'a banned account cannot propose, and the refusal comes from claims_insert_own rather than from the function'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"f1111111-0000-0000-0000-000000000005","role":"authenticated"}';

select throws_ok(
  $$ select public.submit_claim('A claim from an unconfirmed address.', 'research', 5, false) $$,
  '42501'::text, null::text,
  'nor can an unconfirmed one'
);

reset role;

-- ── Exposure ────────────────────────────────────────────────────────────────────────

-- The column the freeze now reads. An author who could write it could unfreeze their own claim
-- after people had answered it, which is the whole thing it exists to prevent.
select ok(
  not has_column_privilege('authenticated', 'public.claims', 'answered_at', 'UPDATE'),
  'answered_at is not client-writable, so nobody can unfreeze their own claim'
);

select ok(
  not has_table_privilege('anon', 'public.claim_tags', 'INSERT'),
  'anon cannot write a tag onto a claim'
);

select ok(
  not has_table_privilege('authenticated', 'public.claim_tags', 'UPDATE'),
  'and nobody can update one: a row here is two foreign keys, so a change is a delete and an insert'
);

select * from finish();

rollback;
