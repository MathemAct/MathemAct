-- Answering a claim: a position and a reason, together.
--
-- What is under test is one deferred constraint and the RPC that satisfies it. The rule: a rating
-- with a score, on a claim the rater did not propose, must be accompanied by a contribution of
-- their own or an endorsement of somebody else's on the same claim, by the time the transaction
-- commits. "No opinion" is exempt, the proposer is exempt, a score-to-score change is exempt, and
-- a rating that existed before the rule is untouched by it.
--
-- **The check runs at commit and this file never commits.** So every assertion about it forces
-- the check with `set constraints … immediate` inside a savepoint, then puts the mode back after
-- the rollback — `SET CONSTRAINTS ALL IMMEDIATE` survives `ROLLBACK TO SAVEPOINT`, which is a trap
-- this project has already paid for. The two constraints are named rather than `all`, so nothing
-- else deferred in this transaction can be what passes or fails.
--
-- Forcing the check fires every event still pending for it, including the fixtures'. So the first
-- assertion proves the fixtures themselves satisfy the rule, and consumes their events, before
-- anything else leans on that.
--
-- The same reason means every other file that inserts a bare rating as a fixture (013, 014, 015,
-- 018, 020, 022, 023) is unaffected: each ends in ROLLBACK and none forces these constraints.
--
-- Fixtures are created as the table owner. Every behavioural assertion runs under `set local role`,
-- because public.answer_claim() is SECURITY INVOKER precisely so that the policies decide.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(29);

-- ── People ──────────────────────────────────────────────────────────────────────────
-- Nine accounts, because auth.users has a partial unique index on email and each plays one part.

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('a7111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-proposer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-writer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-writes@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-endorses@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-declines@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-banned@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-mover@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-bare@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a7111111-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'answer-grandfathered@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id::text like 'a7111111-0000-0000-0000-00000000000_';

update public.profiles set is_banned = true
 where id = 'a7111111-0000-0000-0000-000000000006';

-- ── Two claims, so an endorsement on the wrong one can be tried ────────────────────

insert into public.claims (id, author_id, statement, status, activated_at, area)
values
  ('a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000001',
   'A proof assistant should be required for any computer-assisted case analysis.',
   'active', now(), 'research'),
  ('a7333333-0000-0000-0000-000000000002', 'a7111111-0000-0000-0000-000000000001',
   'Referees should be told when a submission was drafted with a language model.',
   'active', now(), 'research');

-- The proposer's own positions (exempt), the writer's (each with a contribution below), and the
-- mover's "no opinion" (exempt). Every one of these satisfies the rule — asserted first, below.
insert into public.ratings (claim_id, user_id, score) values
  ('a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000001', 6),
  ('a7333333-0000-0000-0000-000000000002', 'a7111111-0000-0000-0000-000000000001', 5),
  ('a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000002', 8),
  ('a7333333-0000-0000-0000-000000000002', 'a7111111-0000-0000-0000-000000000002', 4),
  ('a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000007', null);

insert into public.comments (id, parent_type, parent_id, author_id, body, created_at)
values
  ('a7444444-0000-0000-0000-000000000001', 'claim', 'a7333333-0000-0000-0000-000000000001',
   'a7111111-0000-0000-0000-000000000002',
   'Case analysis by hand is where the errors are, and the count is not reviewable.', now()),
  ('a7444444-0000-0000-0000-000000000002', 'claim', 'a7333333-0000-0000-0000-000000000002',
   'a7111111-0000-0000-0000-000000000002',
   'A referee weighs a draft differently once they know, and they are entitled to.', now());

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'the fixtures satisfy the rule: proposers, writers with contributions, and "no opinion"'
);

set constraints all deferred;

-- A rating that predates the rule. Written with the trigger off, which is exactly the state of
-- every row inserted before this migration: no event was ever queued for it.
--
-- After the assertion above and not before it: Postgres refuses ALTER TABLE on a table with
-- pending trigger events ("cannot ALTER TABLE because it has pending trigger events"), and the
-- fixtures' deferred checks are pending until something fires them. Forcing them is what clears
-- the queue.
alter table public.ratings disable trigger ratings_require_a_contribution;

insert into public.ratings (claim_id, user_id, score) values
  ('a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000009', 6);

alter table public.ratings enable trigger ratings_require_a_contribution;

-- ── A bare position is refused ──────────────────────────────────────────────────────

savepoint bare;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000008","role":"authenticated"}';

insert into public.ratings (claim_id, user_id, score)
values ('a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000008', 7);

reset role;

-- The message is asserted as well as the code: src/lib/claims.ts recognises it by its wording.
select throws_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  '23514'::text,
  'Endorse a contribution that captures your view, or write your own, to record your position.',
  'a score with no contribution and no endorsement is refused at commit'
);

rollback to savepoint bare;
set constraints all deferred;

-- ── With a contribution of their own ────────────────────────────────────────────────

savepoint writes;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.answer_claim(
       'a7333333-0000-0000-0000-000000000001', 7, false,
       'Only if the analysis is long enough that nobody will read it.') $$,
  'a position and a contribution go in together'
);

reset role;

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'and satisfy the rule'
);

select is(
  (select agreement_score from public.comments
    where author_id = 'a7111111-0000-0000-0000-000000000003'),
  7::smallint,
  'the contribution is stamped with the position written in the same call: the rating went first'
);

rollback to savepoint writes;
set constraints all deferred;

-- ── With an endorsement ─────────────────────────────────────────────────────────────

savepoint endorses;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000004","role":"authenticated"}';

select lives_ok(
  $$ select public.answer_claim(
       'a7333333-0000-0000-0000-000000000001', 8, false, null,
       '[{"comment_id": "a7444444-0000-0000-0000-000000000001", "kind": "captures_my_view"}]') $$,
  'a position and an endorsement go in together — the policy sees the rating written a line earlier'
);

reset role;

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'and an endorsement satisfies the rule as well as writing does'
);

select is(
  (select kind::text from public.comment_endorsements
    where user_id = 'a7111111-0000-0000-0000-000000000004'),
  'captures_my_view',
  'the endorsement is recorded with the kind chosen'
);

rollback to savepoint endorses;
set constraints all deferred;

-- ── "No opinion" is exempt ──────────────────────────────────────────────────────────

savepoint declines;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000005","role":"authenticated"}';

select lives_ok(
  $$ select public.answer_claim('a7333333-0000-0000-0000-000000000001', null, true) $$,
  '"no opinion" with nothing else is accepted'
);

reset role;

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'and passes the check: demanding a reason for declining would push people to pick a number'
);

select is(
  (select count(*)::int from public.ratings
    where user_id = 'a7111111-0000-0000-0000-000000000005' and score is null),
  1,
  'stored as NULL on a real row'
);

rollback to savepoint declines;
set constraints all deferred;

-- ── Changing a score is free; a rating from before the rule is untouched ────────────

savepoint changes;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000009","role":"authenticated"}';

select lives_ok(
  $$ select public.answer_claim('a7333333-0000-0000-0000-000000000001', 2, false) $$,
  'somebody who answered before the rule moves from 6 to 2 with no contribution'
);

reset role;

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'and that passes: a score-to-score change fires neither check, so changing your mind stays free'
);

rollback to savepoint changes;
set constraints all deferred;

-- ── "No opinion" to a score is taking a position ────────────────────────────────────

savepoint moves_bare;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000007","role":"authenticated"}';

select lives_ok(
  $$ select public.answer_claim('a7333333-0000-0000-0000-000000000001', 9, false) $$,
  'the update itself goes through — the check is deferred'
);

reset role;

select throws_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  '23514'::text, null::text,
  'but moving from "no opinion" to a score with no reason is refused: otherwise the rule is a two-step bypass'
);

rollback to savepoint moves_bare;
set constraints all deferred;

savepoint moves_with_reason;

-- An earlier contribution, written while they had no opinion.
insert into public.comments (parent_type, parent_id, author_id, body)
values ('claim', 'a7333333-0000-0000-0000-000000000001', 'a7111111-0000-0000-0000-000000000007',
        'I cannot judge the formalisation cost, which is the whole of the disagreement.');

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000007","role":"authenticated"}';

select lives_ok(
  $$ select public.answer_claim('a7333333-0000-0000-0000-000000000001', 9, false) $$,
  'somebody who already wrote on this claim moves from "no opinion" to 9'
);

reset role;

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'and passes: they already have a contribution on this claim'
);

rollback to savepoint moves_with_reason;
set constraints all deferred;

-- ── Nothing is half-saved ───────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000008","role":"authenticated"}';

select throws_ok(
  $$ select public.answer_claim(
       'a7333333-0000-0000-0000-000000000001', 4, false, null,
       '[{"comment_id": "a7444444-0000-0000-0000-000000000002", "kind": "captures_my_view"}]') $$,
  '23514'::text, null::text,
  'an endorsement of a contribution on another claim is refused: it cannot satisfy the rule for this one'
);

reset role;

select is_empty(
  $$ select id from public.ratings where user_id = 'a7111111-0000-0000-0000-000000000008' $$,
  'and the position written before it went with it: one call, one transaction'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ select public.answer_claim(
       'a7333333-0000-0000-0000-000000000001', 8, false, null,
       '[{"comment_id": "a7444444-0000-0000-0000-000000000001", "kind": "captures_my_view"}]') $$,
  '42501'::text, null::text,
  'endorsing your own contribution is refused by the endorsement policy the RPC runs under'
);

reset role;

-- ── Who may answer ──────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000006","role":"authenticated"}';

select throws_ok(
  $$ select public.answer_claim(
       'a7333333-0000-0000-0000-000000000001', 7, false, 'Written after the ban.') $$,
  '42501'::text, null::text,
  'a banned account is refused by ratings_insert_own, not by the function'
);

reset role;

-- ── The proposer is exempt ──────────────────────────────────────────────────────────

savepoint proposes;

set local role authenticated;
set local request.jwt.claims to '{"sub":"a7111111-0000-0000-0000-000000000001","role":"authenticated"}';

select lives_ok(
  $$ select public.submit_claim(
       'A formal proof should accompany every claimed computer-assisted result.', 'research', 4) $$,
  'proposing still writes the proposer''s position with no contribution'
);

reset role;

select lives_ok(
  'set constraints ratings_require_a_contribution, ratings_position_needs_a_contribution immediate',
  'and passes the check: the claim and its rationale are the proposer''s reason'
);

rollback to savepoint proposes;
set constraints all deferred;

-- ── Exposure ────────────────────────────────────────────────────────────────────────

select ok(
  not has_function_privilege('anon', 'public.answer_claim(uuid, integer, boolean, text, jsonb)', 'EXECUTE'),
  'anon cannot answer'
);

select ok(
  has_function_privilege('authenticated', 'public.answer_claim(uuid, integer, boolean, text, jsonb)', 'EXECUTE'),
  'a signed-in account can'
);

select is(
  (select count(*)::int from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'answer_claim'),
  1,
  'exactly one answer_claim: a second overload would make every call ambiguous'
);

select ok(
  not (select p.prosecdef from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'answer_claim'),
  'answer_claim is SECURITY INVOKER: the policies decide, and it authorises nothing'
);

select ok(
  not has_function_privilege('authenticated', 'private.assert_rating_has_contribution()', 'EXECUTE'),
  'the check itself is not callable by a browser role'
);

select is(
  (select count(*)::int from pg_trigger t
    where t.tgrelid = 'public.ratings'::regclass
      and t.tgname in ('ratings_require_a_contribution', 'ratings_position_needs_a_contribution')
      and t.tgdeferrable and t.tginitdeferred),
  2,
  'both checks are deferred to commit, which is what lets the reason follow the position'
);

select * from finish();

rollback;
