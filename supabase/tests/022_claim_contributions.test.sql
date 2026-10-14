-- Claim contributions: the position they were written from, flatness, endorsement, the edit
-- window, supersession, and the rating history.
--
-- **Every rule under test is conditional on the subject being a claim, and half of these
-- assertions exist to prove that the other half did not leak into report threads.** The two
-- content types share public.comments, and a report thread is the one place on this site where
-- nesting is correct. So for each new rule there is a matching assertion that a report comment
-- still behaves as it did: a reply still succeeds, a report comment is still editable while an
-- endorsement exists on a claim contribution elsewhere, and the score column is NULL on it.
--
-- Three of these would pass against a broken implementation if they were written the obvious
-- way, and are written the way they are for that reason:
--
--   The score column is asserted after the author's rating has changed, not only before.
--   Copying the rating at insert and joining it live are indistinguishable until somebody
--   changes their mind, which is the entire reason the column exists.
--
--   The edit window on an endorsed contribution is asserted from the author's side, and the
--   endorsement is made by somebody else. public.comment_endorsements is readable only by the
--   endorser, so an implementation that inlined the existence check in the SECURITY INVOKER
--   guard would see zero endorsements, allow the edit, and look correct in review.
--
--   The score column is asserted to be overwritten with the grant deliberately widened. The
--   protection that matters is the trigger, not the absent grant, and a test that only proves
--   the door is locked says nothing about the floor under it.
--
-- On flatness there are two assertions rather than one, because the rule is written twice on
-- purpose and the two halves fail differently. The constraint is asserted as the table owner,
-- who is not subject to row level security, so what refuses the row is unambiguously the CHECK.
-- The policy's copy of the condition is asserted against the catalogue. Written as a single
-- insert by a browser, the test would be asserting an error code that depends on whether
-- Postgres evaluates a permissive WITH CHECK before or after a table constraint — which is an
-- implementation detail of the server, not a fact about this schema.
--
-- Fixtures are created as the table owner, which the guards trust. Every behavioural assertion
-- runs under `set local role`, because what is being tested is what a browser can do. Note that
-- `id` is absent from the INSERT column grant on public.comments, so nothing inserted as
-- `authenticated` may name it; those rows are found again by their body.
--
-- No savepoints are taken, so there is no deferred-constraint mode to put back.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(36);

-- ── People ──────────────────────────────────────────────────────────────────────────
-- Six, because auth.users has a partial unique index on email and each of these has to be a
-- different account: a rater, a second rater who will endorse, one who declined to answer, a
-- banned one, one who never answered at all, and one kept aside for the widened-grant test so
-- that its extra contribution supersedes nothing else under test.

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('e1111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'rated-six@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('e1111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'endorser@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('e1111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'declined@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('e1111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'banned-rater@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('e1111111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'never-answered@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('e1111111-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'grant-widened@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

-- Scoped to these six rather than the whole table, so this file cannot confirm an account some
-- other fixture deliberately left unconfirmed.
update auth.users set email_confirmed_at = now()
 where id in ('e1111111-0000-0000-0000-000000000001',
              'e1111111-0000-0000-0000-000000000002',
              'e1111111-0000-0000-0000-000000000003',
              'e1111111-0000-0000-0000-000000000004',
              'e1111111-0000-0000-0000-000000000005',
              'e1111111-0000-0000-0000-000000000006');

-- Banned after the rating below is written, so that the endorsement refusal is attributable to
-- the ban and to nothing else. An unrated account is refused on that path too, and a test that
-- satisfied neither condition would not say which one did the work.
update public.profiles set is_banned = true
 where id = 'e1111111-0000-0000-0000-000000000004';

-- ── Something to argue about ────────────────────────────────────────────────────────

insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
) values
  ('e2222222-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000001',
   'published', 'A published report with a thread on it', 'research', 'proof_checking',
   'Confirm a lemma.', 'Stated it in Lean.', 'worked', 'It closed.', 'Lean accepted it.', true);

insert into public.claims (id, author_id, statement, status, activated_at, area)
values
  ('e3333333-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000001',
   'A proof assistant should be required for any computer-assisted case analysis.',
   'active', now(), 'research');

-- ── Positions ───────────────────────────────────────────────────────────────────────
-- Five of the six have answered. Account 3's answer is the off-scale one — a real row whose
-- score is NULL — and account 5 has no row at all. The difference between those two is what
-- most of this file is about.

insert into public.ratings (claim_id, user_id, score) values
  ('e3333333-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000001', 6),
  ('e3333333-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000002', 9),
  ('e3333333-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000003', null),
  ('e3333333-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000004', 5),
  ('e3333333-0000-0000-0000-000000000001', 'e1111111-0000-0000-0000-000000000006', 3);

-- ── Contributions and comments ──────────────────────────────────────────────────────

insert into public.comments (id, parent_type, parent_id, author_id, body, created_at)
values
  -- The one that gets endorsed, and whose edit window therefore closes early.
  ('e4444444-0000-0000-0000-000000000001', 'claim', 'e3333333-0000-0000-0000-000000000001',
   'e1111111-0000-0000-0000-000000000001',
   'Case analysis by hand is where the errors are, and the count is not reviewable.', now()),

  -- Written by the person who declined to put a number on it. The contribution is still worth
  -- having: "outside my expertise, and here is why the question is harder than it looks".
  ('e4444444-0000-0000-0000-000000000002', 'claim', 'e3333333-0000-0000-0000-000000000001',
   'e1111111-0000-0000-0000-000000000003',
   'I cannot judge the formalisation cost, which is the whole of the disagreement.', now()),

  -- A report comment by the account that will endorse, kept reply-free so that it can prove a
  -- report comment is still editable after the claim rule has fired elsewhere.
  ('e4444444-0000-0000-0000-000000000003', 'report', 'e2222222-0000-0000-0000-000000000001',
   'e1111111-0000-0000-0000-000000000002',
   'Did the Lean proof need the decidability instance, or was it incidental?', now()),

  -- Older than the window, with nothing under it and no endorsement on it, so it isolates the
  -- age rule from both early-close rules.
  ('e4444444-0000-0000-0000-000000000004', 'claim', 'e3333333-0000-0000-0000-000000000001',
   'e1111111-0000-0000-0000-000000000002',
   'Written twenty-five hours ago and not touched since.', now() - interval '25 hours'),

  -- A top-level report comment, which a reply is attached to below.
  ('e4444444-0000-0000-0000-000000000005', 'report', 'e2222222-0000-0000-0000-000000000001',
   'e1111111-0000-0000-0000-000000000001',
   'The bound is stated for smooth functions; does it survive the Lipschitz case?', now());

-- ── The position a contribution was written from ─────────────────────────────────────

select is(
  (select agreement_score from public.comments
    where id = 'e4444444-0000-0000-0000-000000000001'),
  6::smallint,
  'a claim contribution stores the score its author held when they wrote it'
);

-- NULL is a position, not an absence. The rater declined, holds a real rating row, and is
-- entitled to contribute; the column carries the decline across.
select is(
  (select agreement_score from public.comments
    where id = 'e4444444-0000-0000-0000-000000000002'),
  null::smallint,
  'a contribution from somebody who chose "no opinion" stores NULL, and is accepted'
);

select is(
  (select agreement_score from public.comments
    where id = 'e4444444-0000-0000-0000-000000000003'),
  null::smallint,
  'a report comment carries no position at all'
);

-- The grant is the closed door. Asserted before the next test props it open.
select ok(
  not has_column_privilege('authenticated', 'public.comments', 'agreement_score', 'INSERT'),
  'authenticated cannot name agreement_score in an insert'
);

select ok(
  not has_column_privilege('authenticated', 'public.comments', 'superseded_by', 'UPDATE'),
  'nor superseded_by in an update'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000005","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('claim', 'e3333333-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000005',
             'A contribution from somebody who has not answered.') $$,
  '23514'::text, null::text,
  'a contribution from somebody with no rating row is refused'
);

reset role;

-- ── The floor under the door ────────────────────────────────────────────────────────
-- The grant is widened on purpose, because the protection being tested is the trigger. An
-- implementation that raised on a mismatch instead of overwriting would pass every other
-- assertion in this file and fail this one.

grant insert (agreement_score) on public.comments to authenticated;

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000006","role":"authenticated"}';

select lives_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body, agreement_score)
     values ('claim', 'e3333333-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000006',
             'Claiming a position I do not hold.', 0) $$,
  'with the grant widened the insert is accepted rather than refused'
);

reset role;

select is(
  (select agreement_score from public.comments
    where body = 'Claiming a position I do not hold.'),
  3::smallint,
  'and the value the client sent is overwritten with the one in their rating row'
);

revoke insert (agreement_score) on public.comments from authenticated;

-- ── Flat on claims, threaded on reports ────────────────────────────────────────────
-- As the owner, so that row level security is not in play and the refusal is the constraint's.
-- The target is top-level and in the same discussion, so private.check_comment_thread() has
-- nothing to object to either: what refuses this row is the subject-type condition and nothing
-- else.

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
     values ('claim', 'e3333333-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000002',
             'e4444444-0000-0000-0000-000000000001',
             'A reply to a contribution.') $$,
  '23514'::text, null::text,
  'the constraint refuses a threaded claim contribution: contributions are flat'
);

-- The same rule's other copy. It is in the policy as well as the constraint because a policy
-- refuses at the endpoint and a constraint is the statement about the table that outlives a
-- policy being rewritten.
select ok(
  (select with_check from pg_policies
    where schemaname = 'public'
      and tablename = 'comments'
      and policyname = 'comments_insert_own') like '%in_reply_to%',
  'and the insert policy carries the same condition, so the endpoint refuses it too'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000002","role":"authenticated"}';

-- The half of the rule that must not have changed.
select lives_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
     values ('report', 'e2222222-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000002',
             'e4444444-0000-0000-0000-000000000005',
             'It survives, with a worse constant.') $$,
  'a reply to a report comment still succeeds: report threads are unchanged'
);

-- ── The edit window ─────────────────────────────────────────────────────────────────

select throws_ok(
  $$ update public.comments
        set body = 'Rewritten a day and an hour later.'
      where id = 'e4444444-0000-0000-0000-000000000004' $$,
  '23514'::text, null::text,
  'an edit at hour twenty-five is refused'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000001","role":"authenticated"}';

-- The control. Without it, the assertion after the endorsement could be passing because the
-- contribution was never editable in the first place.
select lives_ok(
  $$ update public.comments
        set body = 'Case analysis by hand is where the errors are, and there are many cases.'
      where id = 'e4444444-0000-0000-0000-000000000001' $$,
  'an unendorsed contribution is editable inside the window'
);

reset role;

-- ── Endorsement ─────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000002","role":"authenticated"}';

select lives_ok(
  $$ insert into public.comment_endorsements (comment_id, user_id, kind)
     values ('e4444444-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000002', 'captures_my_view') $$,
  'somebody who has answered the claim can say a contribution captures their view'
);

select throws_ok(
  $$ insert into public.comment_endorsements (comment_id, user_id, kind)
     values ('e4444444-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000002', 'agree_position_not_reason') $$,
  '23505'::text, null::text,
  'a second endorsement row by the same person is refused: changing kind is an update'
);

select lives_ok(
  $$ update public.comment_endorsements
        set kind = 'agree_position_not_reason'
      where comment_id = 'e4444444-0000-0000-0000-000000000001'
        and user_id = 'e1111111-0000-0000-0000-000000000002' $$,
  'and changing which of the two it is, is that update'
);

reset role;

-- The assertion the DEFINER helper exists for. The author cannot read the endorsement that
-- closes their window — public.comment_endorsements is own-rows-only, and they are not the
-- endorser — so an inlined existence check inside the SECURITY INVOKER guard would find
-- nothing and let this through.
set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ update public.comments
        set body = 'Rewriting the reason somebody has already said is theirs.'
      where id = 'e4444444-0000-0000-0000-000000000001' $$,
  '23514'::text, null::text,
  'an endorsed contribution cannot be edited, even inside the twenty-four hours'
);

select throws_ok(
  $$ insert into public.comment_endorsements (comment_id, user_id, kind)
     values ('e4444444-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000001', 'captures_my_view') $$,
  '42501'::text, null::text,
  'endorsing your own contribution is refused: it already carries your position'
);

reset role;

-- A report comment, by a different author, while an endorsement exists on a claim
-- contribution. Nothing about the claim rule may reach it.
set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000002","role":"authenticated"}';

select lives_ok(
  $$ update public.comments
        set body = 'Did the Lean proof need decidability, or was the instance incidental?'
      where id = 'e4444444-0000-0000-0000-000000000003' $$,
  'a report comment is still editable while an endorsement exists elsewhere'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000005","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comment_endorsements (comment_id, user_id, kind)
     values ('e4444444-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000005', 'captures_my_view') $$,
  '42501'::text, null::text,
  'endorsing without having answered the claim is refused'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comment_endorsements (comment_id, user_id, kind)
     values ('e4444444-0000-0000-0000-000000000001',
             'e1111111-0000-0000-0000-000000000004', 'captures_my_view') $$,
  '42501'::text, null::text,
  'and a banned account is refused, which is the ninth write path a ban closes'
);

reset role;

-- Names are not public. A count is, and it does not come from here.
set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000003","role":"authenticated"}';

select is(
  (select count(*)::int from public.comment_endorsements),
  0,
  'somebody else''s endorsement is unreadable: endorsing needs a rating, and ratings are private'
);

reset role;

-- ── Superseding ─────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000003","role":"authenticated"}';

insert into public.comments (parent_type, parent_id, author_id, body)
values ('claim', 'e3333333-0000-0000-0000-000000000001',
        'e1111111-0000-0000-0000-000000000003',
        'Having read the thread, the formalisation cost is the answerable part.');

select throws_ok(
  $$ update public.comments
        set superseded_by = 'e4444444-0000-0000-0000-000000000001'
      where id = 'e4444444-0000-0000-0000-000000000005' $$,
  '42501'::text, null::text,
  'superseded_by is not directly writable, so nobody can say somebody else changed their mind'
);

reset role;

select is(
  (select superseded_by from public.comments
    where id = 'e4444444-0000-0000-0000-000000000002'),
  (select id from public.comments
    where body = 'Having read the thread, the formalisation cost is the answerable part.'),
  'a new contribution supersedes the author''s previous one on that claim'
);

select is(
  (select body from public.comments
    where id = 'e4444444-0000-0000-0000-000000000002'),
  'I cannot judge the formalisation cost, which is the whole of the disagreement.',
  'and the superseded contribution keeps its text exactly: nothing is moved or rewritten'
);

-- ── Rating history ──────────────────────────────────────────────────────────────────
-- The move this table exists for: off the scale, then onto it. `<>` would evaluate to NULL on
-- this transition and the trigger would silently not fire, which is why its WHEN clause uses
-- `is distinct from`.

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000003","role":"authenticated"}';

update public.ratings set score = 7
 where claim_id = 'e3333333-0000-0000-0000-000000000001'
   and user_id = 'e1111111-0000-0000-0000-000000000003';

select throws_ok(
  $$ select count(*) from public.rating_changes $$,
  '42501'::text, null::text,
  'authenticated cannot read the rating history: it would be a public voting record'
);

reset role;

set local role anon;

select throws_ok(
  $$ select count(*) from public.rating_changes $$,
  '42501'::text, null::text,
  'and neither can anon'
);

reset role;

select is(
  (select count(*)::int from public.rating_changes),
  1,
  'the move from "no opinion" to a number wrote one history row'
);

select is(
  (select from_score from public.rating_changes),
  null::smallint,
  'whose from_score is NULL, because off the scale is where they were'
);

select is(
  (select to_score from public.rating_changes),
  7::smallint,
  'and whose to_score is where they went'
);

-- The point of storing the position rather than joining it. Before this update the two designs
-- were indistinguishable; after it, a live join would report NULL as 7 and rewrite the record.
select is(
  (select agreement_score from public.comments
    where id = 'e4444444-0000-0000-0000-000000000002'),
  null::smallint,
  'and the contribution written from "no opinion" still says so, after its author moved to 7'
);

-- A touch that changes nothing is not a change of position.
set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000003","role":"authenticated"}';

update public.ratings set score = 7
 where claim_id = 'e3333333-0000-0000-0000-000000000001'
   and user_id = 'e1111111-0000-0000-0000-000000000003';

reset role;

select is(
  (select count(*)::int from public.rating_changes),
  1,
  'and re-saving the same score writes no second row'
);

-- ── Withdrawing an endorsement ──────────────────────────────────────────────────────
-- Added with the DELETE policy in 20260822100000. **A DELETE refused by row level security
-- does not raise** — it matches no rows and reports success — so every assertion here checks
-- whether the row is still there rather than whether the statement threw. A `throws_ok` would
-- pass against a policy that permitted everything.

-- An endorsement for the banned account, inserted as the owner because the insert policy
-- refuses it. This is the row the ban has to fail to remove.
insert into public.comment_endorsements (comment_id, user_id, kind)
values ('e4444444-0000-0000-0000-000000000002',
        'e1111111-0000-0000-0000-000000000004', 'captures_my_view');

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000003","role":"authenticated"}';

delete from public.comment_endorsements
 where comment_id = 'e4444444-0000-0000-0000-000000000001';

reset role;

select is(
  (select count(*)::int from public.comment_endorsements
    where comment_id = 'e4444444-0000-0000-0000-000000000001'),
  1,
  'somebody else''s endorsement cannot be withdrawn, and the attempt removes nothing'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000004","role":"authenticated"}';

delete from public.comment_endorsements
 where comment_id = 'e4444444-0000-0000-0000-000000000002';

reset role;

-- A ban closes write paths and removes nothing already posted. Withdrawing would be a way to
-- retract quietly, which is not what a ban is for — and the update policy already re-tests the
-- ban, so admitting a delete without it would be one rule applied two ways one policy apart.
select is(
  (select count(*)::int from public.comment_endorsements
    where comment_id = 'e4444444-0000-0000-0000-000000000002'),
  1,
  'a banned account cannot withdraw one either: their endorsements stay counted'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"e1111111-0000-0000-0000-000000000002","role":"authenticated"}';

delete from public.comment_endorsements
 where comment_id = 'e4444444-0000-0000-0000-000000000001';

reset role;

select is(
  (select count(*)::int from public.comment_endorsements
    where comment_id = 'e4444444-0000-0000-0000-000000000001'),
  0,
  'but its own author can withdraw it outright'
);

-- The rule that survives withdrawal, and the one most likely to be assumed away: the stamp is
-- never cleared. The text was frozen when somebody said it captured their view, and other
-- people have read it since on that basis — reopening the window because the one endorser
-- changed their mind would let the words move under everybody who read them.
select isnt(
  (select endorsed_at from public.comments
    where id = 'e4444444-0000-0000-0000-000000000001'),
  null::timestamptz,
  'and the edit window stays shut: endorsed_at is stamped once and never reset'
);

select * from finish();

rollback;
