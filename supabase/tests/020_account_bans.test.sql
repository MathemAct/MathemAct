-- Banning an account: the effect, the sentence it sends, and what it refuses.
--
-- 016_moderation.test.sql already proves the effect — a moderator bans a member, not a
-- moderator, not themselves, and the flag flips on a column with no grant behind it. This
-- file is about the three things that were missing around it, each of which made the feature
-- present in the schema and absent in practice:
--
--   **The banned account is told, in writing.** A ban is the harshest thing a moderator can
--   do here, it is the one decision that reaches somebody with no post attached to it, and
--   until 20260819120000 the explanation the function *insists* on went to the audit log and
--   stopped. Every assertion about public.moderation_notices below is really an assertion
--   about that: the reason exists, the person it is about can read it, and nobody else can.
--
--   **It can be lifted, and lifting it says so too.** An unban is its own decision with its
--   own sentence, not the absence of a ban.
--
--   **It cannot be repeated.** The effect of banning twice is nothing; the *notification* of
--   banning twice is a second message telling somebody something that did not happen. The
--   refusal is what keeps a feed honest.
--
-- The last section is the point of the whole feature and belongs in a test rather than in a
-- runbook: a banned account cannot write. Every content table is asserted from the banned
-- side, because "a ban means a ban" appears in **nine** insert policies and one of them being
-- wrong would look exactly like a member having a bad day.
--
-- The count has now been wrong twice, in opposite directions, which is the argument for
-- asserting each policy by hand rather than trusting any list of them. The first version of
-- this file and the runbook beside it both said seven and both forgot public.citations, making
-- it eight. 20260821120200 added public.comment_endorsements, making it nine. Every place that
-- states the number — this header, docs/moderation.md, the README and CLAUDE.md — has been
-- wrong about it at some point, and none of them is load-bearing: the assertions below are.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(34);

-- ── People ──────────────────────────────────────────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'spammer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'member@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'moderator@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'second@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

update public.profiles set role = 'moderator' where id = '11111111-0000-0000-0000-000000000003';

-- Something for the banned account to have posted, so that the assertion further down —
-- that a ban leaves the corpus alone — is about a real row rather than about an empty table.
insert into public.reports (
  id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
) values
  ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'Posted before the ban', 'research', 'computation',
   'Generate examples.', 'Asked for twenty.', 'partial', 'Sixteen were right.',
   'Checked all twenty by hand.', true),

  ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000002',
   'Somebody else''s report', 'research', 'proof_checking',
   'Confirm a lemma.', 'Stated it in Lean.', 'worked', 'It closed.', 'Lean accepted it.', true);

insert into public.claims (id, author_id, statement, area)
values ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000002',
        'AI-assisted literature search should be disclosed in papers.', 'writing');

-- Both accounts answer the claim before the ban, and somebody else writes a contribution to
-- it. This is scaffolding for the ninth write path: endorsing requires a rating and refuses
-- your own contribution, so without all three rows the refusal below would be attributable to
-- a missing rating rather than to the ban, and would pass for the wrong reason.
insert into public.ratings (claim_id, user_id, score) values
  ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 3),
  ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000002', 8);

insert into public.comments (id, parent_type, parent_id, author_id, body)
values ('44444444-0000-0000-0000-000000000001', 'claim',
        '33333333-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000002',
        'Disclosure costs nothing, and the alternative is a claim nobody can check.');

-- ── A ban needs a sentence, and refuses without one ─────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000001', 'ban') $$,
  '23514'::text, null::text,
  'a ban with no explanation is refused: the explanation is the part the account holder reads'
);

select throws_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000001', 'ban', '   ') $$,
  '23514'::text, null::text,
  'and whitespace is not an explanation'
);

select throws_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000001', 'unban',
                            'Nothing to lift.') $$,
  '23514'::text, null::text,
  'an account that is not banned cannot be unbanned'
);

select lives_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000001', 'ban',
                            'Eleven network entries advertising the same product in one afternoon.') $$,
  'a moderator bans an account for spamming'
);

-- Twice is the one that matters. The effect is idempotent and the notification is not.
select throws_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000001', 'ban',
                            'Still spamming.') $$,
  '23514'::text, null::text,
  'banning an already banned account is refused rather than repeated'
);

reset role;

select is(
  (select is_banned from public.profiles where id = '11111111-0000-0000-0000-000000000001'),
  true,
  'the ban took effect on a column with no grant behind it'
);

-- ── The audit row, and the sentence addressed to the person ─────────────────────────

select is(
  (select count(*)::int from public.moderation_actions
    where action = 'ban' and target_id = '11111111-0000-0000-0000-000000000001'),
  1,
  'one audit row, naming the moderator and the account'
);

select is(
  (select count(*)::int from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'),
  1,
  'and one notice, addressed to the account banned'
);

select is(
  (select subject_type::text from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'),
  'account',
  'the notice is about an account, which the old CHECK on this table forbade outright'
);

select is(
  (select outcome::text from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'),
  'banned',
  'with the outcome in the words a member reads'
);

select is(
  (select recipient_role::text from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'),
  'account_holder',
  'and a role saying why they are being told: not as an author, not as a flagger'
);

select is(
  (select explanation from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'),
  'Eleven network entries advertising the same product in one afternoon.',
  'the sentence the moderator wrote reaches them unchanged'
);

select is(
  (select label from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'),
  null::text,
  'and carries no label: the only heading an account has is the name of the person reading it'
);

-- The notice points at the audit row it reports, which is what makes the two halves of one
-- decision inseparable afterwards.
select is(
  (select count(*)::int
     from public.moderation_notices n
     join public.moderation_actions a on a.id = n.action_id
    where n.recipient_id = '11111111-0000-0000-0000-000000000001'
      and a.action = 'ban'),
  1,
  'the notice reports a real audit row rather than standing alone'
);

-- ── The feed says it happened; the notice says why ──────────────────────────────────

select is(
  (select count(*)::int from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'account_banned'),
  1,
  'the account has a feed row telling it to come and look'
);

select is(
  (select is_inbound from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'account_banned'),
  true,
  'counted as unread: it is something that happened to them, not something they did'
);

select is(
  (select count(*)::int from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'account_banned'
      and actor_id is not null),
  0,
  'and it does not name the moderator, in this table any more than in the notice'
);

-- ── Who may read it ─────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select is(
  (select count(*)::int from public.moderation_notices),
  1,
  'the banned account reads its own notice'
);

select is(
  (select count(*)::int from public.moderation_actions),
  0,
  'and not the log, which names the moderator and is written to other moderators'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000004","role":"authenticated"}';

select is(
  (select count(*)::int from public.moderation_notices),
  0,
  'a bystander reads neither'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select cmp_ok(
  (select count(*)::int from public.moderation_notices),
  '>',
  0,
  'a moderator can see what was written, so a second one is not deciding blind'
);

reset role;

-- ── A ban stops writing and nothing else ────────────────────────────────────────────
-- Nine policies carry `not p.is_banned`. Each is asserted from the banned side, because a
-- ban that silently permitted one kind of write would present as a member having a bad day.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports (author_id, title, area, task_type, aim, method, outcome,
                                 outcome_notes, verification, third_party_material_confirmed)
     values ('11111111-0000-0000-0000-000000000001', 'After the ban', 'research',
             'computation', 'Try again.', 'Asked once more.', 'worked', 'Fine.',
             'Checked by hand.', true) $$,
  '42501'::text, null::text,
  'a banned account cannot post a report'
);

select throws_ok(
  $$ insert into public.claims (author_id, statement, area)
     values ('11111111-0000-0000-0000-000000000001',
             'A claim posted after the ban.', 'research') $$,
  '42501'::text, null::text,
  'nor a claim'
);

select throws_ok(
  $$ insert into public.network_entries (submitter_id, title, url, category, description,
                                        relevance)
     values ('11111111-0000-0000-0000-000000000001', 'One more advertisement',
             'https://example.com/again', 'reading',
             'The same product as the other eleven.',
             'Everyone needs this before the price rises.') $$,
  '42501'::text, null::text,
  'nor a network entry, which is what the ban was for'
);

select throws_ok(
  $$ insert into public.comments (parent_type, parent_id, author_id, body)
     values ('report', '22222222-0000-0000-0000-000000000002',
             '11111111-0000-0000-0000-000000000001', 'A comment after the ban.') $$,
  '42501'::text, null::text,
  'nor a comment'
);

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('33333333-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000001', 8) $$,
  '42501'::text, null::text,
  'nor a rating'
);

select throws_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('22222222-0000-0000-0000-000000000002',
             '11111111-0000-0000-0000-000000000001', 'still_works') $$,
  '42501'::text, null::text,
  'nor a confirmation'
);

select throws_ok(
  $$ insert into public.flags (subject_type, subject_id, flagger_id, reason)
     values ('report', '22222222-0000-0000-0000-000000000002',
             '11111111-0000-0000-0000-000000000001', 'off_topic') $$,
  '42501'::text, null::text,
  'and cannot flag, which would otherwise make a ban a promotion to critic'
);

-- The eighth, and the one the first version of this file missed. Every clause of
-- citations_insert_own is satisfied here except the ban: both ends exist, the types differ so
-- it is not a self-citation, and there is no source comment to have to own. So the refusal is
-- attributable to `not p.is_banned` and to nothing else, which is what makes the assertion
-- worth having rather than merely green.
select throws_ok(
  $$ insert into public.citations (source_type, source_id, target_type, target_id,
                                   context, created_by)
     values ('report', '22222222-0000-0000-0000-000000000001',
             'claim', '33333333-0000-0000-0000-000000000001',
             'Relevant to the claim.', '11111111-0000-0000-0000-000000000001') $$,
  '42501'::text, null::text,
  'nor cite one thing from another'
);

-- The ninth, added with public.comment_endorsements in 20260821120200. Every other clause of
-- comment_endorsements_insert_own is satisfied: the account holds a rating on that claim, the
-- contribution is somebody else's, it is live and on a claim. So the refusal is attributable
-- to `not p.is_banned` and to nothing else.
select throws_ok(
  $$ insert into public.comment_endorsements (comment_id, user_id, kind)
     values ('44444444-0000-0000-0000-000000000001',
             '11111111-0000-0000-0000-000000000001', 'captures_my_view') $$,
  '42501'::text, null::text,
  'nor say that somebody else''s contribution captures their view'
);

-- What a ban is not. Reading is untouched, and so is the way out: an account that could not
-- ask to be erased would be one somebody had been locked inside.
select lives_ok(
  $$ insert into public.deletion_requests (user_id, note)
     values ('11111111-0000-0000-0000-000000000001', 'I would like the account removed.') $$,
  'a banned account may still ask to be erased: a ban is not a locked door'
);

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000001'),
  'published',
  'and what they posted before the ban is still in the corpus: hiding a post is a separate decision'
);

-- ── Lifting it ──────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000001', 'unban',
                            'The entries came down and the account has undertaken not to repeat it.') $$,
  'a ban can be lifted, with an explanation of its own'
);

reset role;

select is(
  (select count(*)::int from public.moderation_notices
    where recipient_id = '11111111-0000-0000-0000-000000000001'
      and outcome = 'unbanned'),
  1,
  'and being readmitted is told to the account as its own decision, not as the absence of one'
);

select * from finish();

rollback;
