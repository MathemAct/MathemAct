-- Who may read, write, edit and delete a comment.
--
-- Three behaviours here are the ones worth having tests for, because each looks wrong from
-- the outside and each is deliberate:
--
--   A comment on a hidden report is invisible, without anything having walked the thread
--   and hidden each row. The select policy requires a parent the caller can see, so it
--   composes with whatever public.reports already says.
--
--   Soft deletion empties the body and nulls the author in a BEFORE trigger, and the
--   policy's WITH CHECK then requires exactly that shape. The test asserts the outcome
--   rather than the mechanism: no name, no text, node still there, reply still readable.
--
--   The 24 hour edit window raises rather than reverting. It cannot live in a policy —
--   permissive policies are OR'd, and the soft-delete policy would grant round it — so it
--   is in the guard, and the observable behaviour is an error and not a silent no-op.
--
-- Fixtures are created as the table owner, which the guards trust. Every assertion runs
-- under `set local role`, because what is being tested is what a browser can do.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(36);

-- ── People ──────────────────────────────────────────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'author@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'reader@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'unconfirmed@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'banned@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'moderator@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id <> '11111111-0000-0000-0000-000000000003';

update public.profiles set is_banned = true
 where id = '11111111-0000-0000-0000-000000000004';

update public.profiles set role = 'moderator'
 where id = '11111111-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.profiles where confirmed_at is not null),
  4,
  'four of the five fixtures have a confirmed account'
);

-- ── Things to comment on ────────────────────────────────────────────────────────────

insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
) values
  ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'published', 'A published report', 'research', 'proof_checking',
   'Confirm a lemma.', 'Stated it in Lean.', 'worked', 'It closed.', 'Lean accepted it.', true),

  -- A leftover from the retired approval queue. Nothing is written in this status now, and
  -- the read policies still have to keep it out of sight.
  ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
   'pending', 'A report left over from the approval queue', 'writing', 'exposition',
   'Draft a seminar note.', 'Asked, then rewrote.', 'partial', 'Half usable.',
   'Checked by hand.', true),

  ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001',
   'hidden', 'A report a moderator has hidden', 'research', 'other',
   'Something.', 'Something else.', 'failed', 'It did not.', 'Checked it.', true);

insert into public.claims (id, author_id, statement, status, activated_at, area)
values
  ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'Every AI-generated proof step must be checked by a human before publication.',
   'active', now(), 'research');

-- A position for account 1, because 20260821120000 refuses a contribution to a claim its
-- author has not answered: a contribution is the reason for a position, so there has to be
-- one. Without this the claim comment below is refused and every assertion after it fails
-- for a reason that has nothing to do with what this file tests.
insert into public.ratings (claim_id, user_id, score)
values ('33333333-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000001', 4);

-- ── Comments ────────────────────────────────────────────────────────────────────────

insert into public.comments (id, parent_type, parent_id, author_id, in_reply_to, body, status, created_at)
values
  ('44444444-0000-0000-0000-000000000001', 'report', '22222222-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000002', null,
   'Did the missing hypothesis turn out to be necessary, or only convenient?', 'published', now()),

  ('44444444-0000-0000-0000-000000000002', 'report', '22222222-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000001',
   'Necessary. The statement is false without it.', 'published', now()),

  ('44444444-0000-0000-0000-000000000003', 'report', '22222222-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000002', null,
   'A remark a moderator has since hidden.', 'hidden', now()),

  -- Authored by 1, not by 2. The reader who tries to reply to this below has to be somebody
  -- who genuinely cannot see it: an author can always read their own comment, whatever has
  -- happened to the report it hangs off, so making this 2's own would test nothing.
  ('44444444-0000-0000-0000-000000000004', 'report', '22222222-0000-0000-0000-000000000003',
   '11111111-0000-0000-0000-000000000001', null,
   'A remark on a report that is no longer visible.', 'published', now()),

  ('44444444-0000-0000-0000-000000000005', 'claim', '33333333-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000001', null,
   'Checked how? $\pi_1$ of the wrong space is still a check.', 'published', now()),

  -- Older than the edit window, and with nothing under it, so it isolates the age rule
  -- from the replies rule.
  ('44444444-0000-0000-0000-000000000006', 'report', '22222222-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000001', null,
   'Written three days ago and never touched since.', 'published', now() - interval '3 days');

-- ── Reading ─────────────────────────────────────────────────────────────────────────

set local role anon;

select is(
  (select count(*)::int from public.comments),
  4,
  'anon sees published comments on visible parents and nothing else'
);

select is_empty(
  $$ select id from public.comments where status <> 'published' $$,
  'anon sees no hidden comment'
);

select is_empty(
  $$ select id from public.comments where parent_id = '22222222-0000-0000-0000-000000000003' $$,
  'anon sees no comment on a hidden report, without those rows having been hidden too'
);

select is(
  (select count(*)::int from public.comments where parent_type = 'claim'),
  1,
  'the same thread machinery serves claims'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

select is(
  (select count(*)::int from public.comments where status = 'hidden'),
  1,
  'an author sees their own comment after it has been hidden, so moderation is discoverable'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select is(
  (select count(*)::int from public.comments),
  6,
  'a moderator sees every comment, including those on hidden parents'
);

reset role;

-- ── Writing: who may comment at all ─────────────────────────────────────────────────

set local role anon;

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000002', 'From nowhere.') $$,
  '42501'::text, null::text,
  'anon cannot comment'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000003', 'Unconfirmed.') $$,
  '42501'::text, null::text,
  'an unconfirmed account cannot comment'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000004', 'Banned.') $$,
  '42501'::text, null::text,
  'a banned account cannot comment'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000001', 'Under a false name.') $$,
  '42501'::text, null::text,
  'a member cannot comment under somebody else''s name'
);

-- The parent is real; this caller simply cannot see it. Somebody else's pending submission
-- must not be discoverable by commenting on its id.
select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('report', '22222222-0000-0000-0000-000000000002',
             '11111111-0000-0000-0000-000000000002', 'On a queued submission.') $$,
  '42501'::text, null::text,
  'a member cannot comment on a parent they cannot see'
);

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, status, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000002', 'hidden', 'Born hidden.') $$,
  '42501'::text, null::text,
  'nobody can choose a comment''s status: it has no INSERT grant'
);

-- The allowed case.
insert into public.comments (parent_type, parent_id, author_id, body)
values ('report', '22222222-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000002',
        'An ordinary remark from a confirmed member.');

reset role;

select is(
  (select status::text from public.comments
    where body = 'An ordinary remark from a confirmed member.'),
  'published'::text,
  'a confirmed member may comment, and the comment is published at once'
);

-- ── One level of nesting ────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000002',
             '44444444-0000-0000-0000-000000000002', 'A reply to a reply.') $$,
  '23514'::text, null::text,
  'a reply to a reply is refused: nesting stops at one level'
);

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
     values ('claim', '33333333-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000002',
             '44444444-0000-0000-0000-000000000001', 'A reply from another discussion.') $$,
  '23514'::text, null::text,
  'a reply cannot be attached to a discussion other than its own'
);

-- A comment the caller cannot see and a comment that does not exist give the same answer,
-- deliberately: distinguishing them would make the endpoint a way to probe by id.
select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
     values ('report', '22222222-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000002',
             '44444444-0000-0000-0000-000000000004', 'A reply to a comment on a hidden report.') $$,
  '23503'::text, null::text,
  'a reply to a comment the caller cannot see is refused, and says nothing about why'
);

-- The allowed case: one reply, to a top-level comment, in its own discussion.
insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
values ('report', '22222222-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000002',
        '44444444-0000-0000-0000-000000000006', 'A perfectly ordinary reply.');

reset role;

select is(
  (select in_reply_to from public.comments where body = 'A perfectly ordinary reply.'),
  '44444444-0000-0000-0000-000000000006'::uuid,
  'a reply to a top-level comment in the same discussion is accepted'
);

-- ── Editing ─────────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

update public.comments
   set body = 'An ordinary remark, with the typo fixed.'
 where body = 'An ordinary remark from a confirmed member.';

reset role;

select is(
  (select count(*)::int from public.comments
    where body = 'An ordinary remark, with the typo fixed.'),
  1,
  'an author may edit their own comment inside the window'
);

-- The window is 24 hours because comments carry TeX, TeX renders at build time, and the
-- build is nightly: an author's first sight of their own formula is up to a day later.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ update public.comments set body = 'Rewritten three days later.'
      where id = '44444444-0000-0000-0000-000000000006' $$,
  '23514'::text, null::text,
  'an author cannot edit their own comment once the 24 hour window has passed'
);

reset role;

-- And the window closes early once anybody has answered. Comment 1 was written moments
-- ago, so the age rule cannot be what refuses this: people replied to the sentence in
-- front of them, and rewriting it makes their reply answer something they never read.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ update public.comments set body = 'Rewritten under the replies.'
      where id = '44444444-0000-0000-0000-000000000001' $$,
  '23514'::text, null::text,
  'a comment with replies has its text frozen, however recent it is'
);

-- Somebody else's comment matches no policy's USING clause, so this is a silent no-op
-- rather than an error -- the same shape as editing another member's report.
update public.comments set body = 'Hijacked.'
 where id = '44444444-0000-0000-0000-000000000005';

reset role;

select isnt(
  (select body from public.comments where id = '44444444-0000-0000-0000-000000000005'),
  'Hijacked.'::text,
  'a member cannot edit somebody else''s comment'
);

-- ── Soft deletion ───────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

update public.comments set deleted_at = now()
 where id = '44444444-0000-0000-0000-000000000001';

reset role;

select is(
  (select body from public.comments where id = '44444444-0000-0000-0000-000000000001'),
  ''::text,
  'deleting a comment empties its body: the text is not kept anywhere'
);

select is(
  (select author_id from public.comments where id = '44444444-0000-0000-0000-000000000001'),
  null::uuid,
  'and strips the attribution in the same statement'
);

select is(
  (select count(*)::int from public.comments
    where in_reply_to = '44444444-0000-0000-0000-000000000001'),
  1,
  'but the node remains, so the reply under it still reads as a reply'
);

set local role anon;

select is(
  (select count(*)::int from public.comments
    where id = '44444444-0000-0000-0000-000000000001'),
  1,
  'a deleted comment is still returned, because the thread structure is the point'
);

reset role;

-- The author is no longer the author -- that is what stripping means -- so nothing they
-- do reaches this row again, including putting it back.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

update public.comments set deleted_at = null, body = 'Back again.'
 where id = '44444444-0000-0000-0000-000000000001';

reset role;

select is(
  (select body from public.comments where id = '44444444-0000-0000-0000-000000000001'),
  ''::text,
  'and a deleted comment cannot be restored: there is nothing stored to restore it to'
);

-- ── Moderation ──────────────────────────────────────────────────────────────────────
-- The moderator UPDATE policy on this table was dropped in 20260815200300: hiding a comment
-- goes through public.moderate(), which writes an audit row in the same transaction.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('comment', '44444444-0000-0000-0000-000000000005', 'hide',
                            'Names a pseudonymous contributor.') $$,
  'a moderator may hide a comment: the hide path works'
);

reset role;

select is(
  (select status::text from public.comments where id = '44444444-0000-0000-0000-000000000005'),
  'hidden'::text,
  'and it is hidden'
);

-- The unaudited way, which no policy admits any more: it succeeds and changes nothing.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

update public.comments set status = 'published'
 where id = '44444444-0000-0000-0000-000000000005';

reset role;

select is(
  (select status::text from public.comments where id = '44444444-0000-0000-0000-000000000005'),
  'hidden'::text,
  'a direct update by a moderator changes nothing: the audit log cannot be stepped around'
);

-- Hiding preserves the text and the name, which is what makes it reviewable and
-- reversible. Editing somebody else's words under their name is not a moderation power in
-- any tradition worth copying, and it is out of reach twice over: no policy accepts the
-- update, and public.moderate() has no branch that touches a body.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

update public.comments set body = 'Improved by the moderation team.'
 where id = '44444444-0000-0000-0000-000000000005';

reset role;

select isnt(
  (select body from public.comments where id = '44444444-0000-0000-0000-000000000005'),
  'Improved by the moderation team.'::text,
  'a moderator cannot rewrite a comment; only its status is theirs'
);

select isnt(
  (select author_id from public.comments where id = '44444444-0000-0000-0000-000000000005'),
  null::uuid,
  'and hiding keeps the attribution, unlike deleting'
);

-- ── No hard delete ──────────────────────────────────────────────────────────────────

select ok(
  not has_table_privilege('authenticated', 'public.comments', 'DELETE'),
  'there is no DELETE grant on comments: removing a row would take its replies with it'
);

-- ── The rate limit is actually attached ─────────────────────────────────────────────
-- private.enforce_daily_limit() raises on a table it has no rule for, so a trigger that
-- exists is a trigger that works. What this catches is the trigger not existing at all,
-- which is invisible until somebody posts four hundred comments.

select has_trigger(
  'public', 'comments', 'comments_daily_limit',
  'comments are rate limited by the same trigger as reports'
);

-- ── Erasure detaches rather than destroys ───────────────────────────────────────────

delete from auth.users where id = '11111111-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.comments where id = '44444444-0000-0000-0000-000000000002'),
  1,
  'erasing an account leaves its comments in place, so the threads do not collapse'
);

select is(
  (select author_id from public.comments where id = '44444444-0000-0000-0000-000000000002'),
  null::uuid,
  'and strips their attribution'
);

select * from finish();

rollback;
