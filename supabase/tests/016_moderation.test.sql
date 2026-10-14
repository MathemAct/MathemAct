-- Moderation: the audited path, the log behind it, the sentence it sends, and what it refuses.
--
-- Two assertions this file exists for, and both are easy to lose later.
--
-- **There is no unaudited way to moderate.** Two halves have to hold at once — public.moderate()
-- works, and the direct UPDATE that used to do the same job no longer does. A test of only
-- the first half would still pass on the day somebody re-adds a moderator policy "so the
-- queue can be fixed quickly", which is exactly how audit logs stop being complete.
--
-- **Nothing waits to be published, and every decision reaches a person.** Since the move to
-- post-moderation a report is in the corpus the moment it is written, and the moderator's
-- work is answering flags. Each answer writes public.moderation_notices rows addressed to
-- the author of the post and to whoever flagged it — which is the only route either of them
-- has to the reason, because the log itself is moderators-only and stays that way.
--
-- The rest of the file is about what a moderator may not do: judge their own work, answer
-- their own flag, ban somebody with standing, ban themselves, erase an account that never
-- asked, or edit the record afterwards. Each of those is a sentence in docs/moderation.md,
-- and a promise in a document that nothing enforces is a promise about intentions.
--
-- The last two sections destroy fixtures — an erasure really does delete the account — so
-- they come last and nothing after them may depend on those rows.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(87);

-- ── People ──────────────────────────────────────────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'author@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'reader@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'moderator@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'admin@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'leaver@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

update public.profiles set role = 'moderator' where id = '11111111-0000-0000-0000-000000000003';
update public.profiles set role = 'admin'     where id = '11111111-0000-0000-0000-000000000004';

-- ── Things to decide about ──────────────────────────────────────────────────────────
-- `status` is deliberately not named on the first row: the default is the whole of the
-- change this file is testing, and a fixture that spelled it out would keep passing on the
-- day somebody set it back to 'pending'.

insert into public.reports (
  id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
) values
  ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'Posted and readable', 'research', 'proof_checking',
   'Confirm a lemma.', 'Stated it in Lean.', 'worked', 'It closed.', 'Lean accepted it.', true),

  ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
   'Already in the corpus', 'research', 'literature_search',
   'Find prior art.', 'Asked, then checked each.', 'partial', 'Two references invented.',
   'Looked every one up.', true),

  -- The moderator's own. This is the row the no-self-judgement rule is about.
  ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000003',
   'Posted by the moderator', 'writing', 'exposition',
   'Draft a note.', 'Asked, rewrote.', 'partial', 'Half usable.', 'Checked by hand.', true),

  -- Posted by the account that will later be erased.
  ('22222222-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000005',
   'By somebody who later left', 'learning', 'computation',
   'Generate examples.', 'Asked for twenty.', 'worked', 'Sixteen were right.',
   'Checked all twenty by hand.', true),

  ('22222222-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000002',
   'Flagged and left alone', 'research', 'proof_drafting',
   'Prove a bound.', 'Asked for a sketch.', 'partial', 'The sketch had a gap.',
   'Checked the induction step by hand.', true);

-- Same again: no status, no activated_at. Both defaults or the CHECK fails.
insert into public.claims (id, author_id, statement, area)
values
  ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000002',
   'AI-assisted literature search should be disclosed in papers.', 'writing'),

  ('33333333-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000003',
   'A proof assistant should check every AI-drafted lemma before submission.', 'research'),

  ('33333333-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001',
   'Referees should be told when a paper used a model for exposition.', 'writing');

-- What freezes the first report. Without an answer on it, a published report is still its
-- author's to correct, which is the whole point of the new editing rule — so the assertion
-- further down that a published report cannot be rewritten needs a report somebody has
-- answered, not merely a published one.
insert into public.report_confirmations (report_id, user_id, verdict)
values ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000002',
        'still_works');

insert into public.comments (id, parent_type, parent_id, author_id, body)
values
  ('44444444-0000-0000-0000-000000000001', 'report', '22222222-0000-0000-0000-000000000002',
   '11111111-0000-0000-0000-000000000002', 'Was the hypothesis necessary or convenient?'),
  ('44444444-0000-0000-0000-000000000002', 'report', '22222222-0000-0000-0000-000000000002',
   '11111111-0000-0000-0000-000000000003', 'A remark from the moderator, in their own name.'),
  -- Somebody else's, untouched by every decision below, so that the direct-update assertion
  -- at the end is about a policy refusing a moderator rather than about a guard reverting
  -- somebody's edit to their own comment.
  ('44444444-0000-0000-0000-000000000003', 'report', '22222222-0000-0000-0000-000000000005',
   '11111111-0000-0000-0000-000000000001', 'Does the bound hold without the smoothness assumption?');

insert into public.flags (id, subject_type, subject_id, flagger_id, reason, detail)
values
  ('66666666-0000-0000-0000-000000000001', 'comment', '44444444-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000001', 'off_topic',
   'This is about the referee process rather than about the tool.'),

  -- Two flags on one report, by two people. Hiding it has to answer both.
  ('66666666-0000-0000-0000-000000000002', 'report', '22222222-0000-0000-0000-000000000002',
   '11111111-0000-0000-0000-000000000002', 'third_party_material',
   'The transcript quotes a referee report.'),
  ('66666666-0000-0000-0000-000000000003', 'report', '22222222-0000-0000-0000-000000000002',
   '11111111-0000-0000-0000-000000000004', 'third_party_material',
   'Same: that is not the author''s to reproduce.'),

  -- The one that will be dismissed.
  ('66666666-0000-0000-0000-000000000004', 'report', '22222222-0000-0000-0000-000000000005',
   '11111111-0000-0000-0000-000000000001', 'inaccurate',
   'I do not believe the tool can do this.'),

  -- Raised by the moderator, so that nobody can answer their own.
  ('66666666-0000-0000-0000-000000000005', 'claim', '33333333-0000-0000-0000-000000000003',
   '11111111-0000-0000-0000-000000000003', 'off_topic',
   'Not about mathematical work.');

insert into public.deletion_requests (id, user_id, note)
values
  ('77777777-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000005',
   'Please detach my reports rather than deleting them.');

-- ── Nothing waits ───────────────────────────────────────────────────────────────────

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000001'),
  'published'::text,
  'a report is published when it is written: no queue, no approval'
);

select is(
  (select status::text from public.claims where id = '33333333-0000-0000-0000-000000000001'),
  'active'::text,
  'and a claim is part of the record when it is written'
);

select isnt(
  (select activated_at from public.claims where id = '33333333-0000-0000-0000-000000000001'),
  null::timestamptz,
  'with the date that says when, which the CHECK ties to the status'
);

-- ── The shape of the log ────────────────────────────────────────────────────────────
-- Grants first, because a missing grant and a missing policy are indistinguishable from a
-- client and these decide whether the endpoint exists at all.

select ok(
  not has_table_privilege('anon', 'public.moderation_actions', 'SELECT'),
  'anon has no endpoint on the moderation log at all'
);

select ok(
  not has_table_privilege('authenticated', 'public.moderation_actions', 'INSERT'),
  'no browser role can write an audit row: rows come only from public.moderate()'
);

select ok(
  not has_table_privilege('authenticated', 'public.moderation_actions', 'UPDATE'),
  'and none can rewrite one'
);

select ok(
  not has_table_privilege('authenticated', 'public.moderation_actions', 'DELETE'),
  'and none can remove one'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.moderation_actions'::regclass),
  'row level security is enabled on the moderation log'
);

-- ── The shape of a notice ───────────────────────────────────────────────────────────
-- The same three questions about the table that carries a decision to the people it is
-- about. A notification a member could write is a notification nobody can trust.

select ok(
  not has_table_privilege('anon', 'public.moderation_notices', 'SELECT'),
  'anon has no endpoint on moderation notices'
);

select ok(
  not has_table_privilege('authenticated', 'public.moderation_notices', 'INSERT'),
  'and nobody can forge one from a browser'
);

select ok(
  not has_table_privilege('authenticated', 'public.moderation_notices', 'UPDATE'),
  'nor edit one after the fact'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.moderation_notices'::regclass),
  'row level security is enabled on moderation notices'
);

-- ── Who may act ─────────────────────────────────────────────────────────────────────

set local role anon;

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'hide', 'No.') $$,
  '42501'::text, null::text,
  'an anonymous caller cannot reach public.moderate() at all'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'hide', 'No.') $$,
  '42501'::text, null::text,
  'an ordinary member cannot hide anything, including their own report'
);

reset role;

-- A banned moderator is not a moderator. The same clause appears in every policy on this
-- site; here it has to be inside the function, because a DEFINER function is not subject to
-- the policies that would otherwise carry it.
update public.profiles set is_banned = true where id = '11111111-0000-0000-0000-000000000003';

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'hide', 'No.') $$,
  '42501'::text, null::text,
  'a banned moderator cannot moderate'
);

reset role;

update public.profiles set is_banned = false where id = '11111111-0000-0000-0000-000000000003';

-- ── The gate is gone, by name ───────────────────────────────────────────────────────
-- Refusing rather than quietly doing nothing. A moderator who has not read the migration
-- will press one of these, and "that action does not apply" would read as a bug.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000001', 'publish', 'Fine.') $$,
  '0A000'::text, null::text,
  'publishing is not a moderation action any more: there is nothing to approve'
);

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000001',
                            'request_changes', 'Say what you checked.') $$,
  '0A000'::text, null::text,
  'nor is sending something back: there is no state to send it back to'
);

select throws_ok(
  $$ select public.moderate('claim', '33333333-0000-0000-0000-000000000001', 'promote', 'Good one.') $$,
  '0A000'::text, null::text,
  'nor promoting a claim, which is part of the record already'
);

-- ── The explanation ─────────────────────────────────────────────────────────────────
-- Everything but carrying out an erasure request needs one, and it is refused before
-- anything happens rather than after.

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'hide') $$,
  '23514'::text, null::text,
  'hiding without an explanation is refused before anything is hidden'
);

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'hide', '   ') $$,
  '23514'::text, null::text,
  'and whitespace is not an explanation'
);

select throws_ok(
  $$ select public.moderate('flag', '66666666-0000-0000-0000-000000000004', 'dismiss_flag') $$,
  '23514'::text, null::text,
  'dismissing a flag needs one too: "we looked and did nothing" is the answer hardest to take'
);

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  'published'::text,
  'the report is untouched by the refused hide'
);

-- ── Hiding, which is the path nothing ships without ─────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'hide',
                            'The transcript reproduces a referee report, which is not yours to publish.') $$,
  'a moderator hides a flagged report'
);

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  'hidden'::text,
  'and it is hidden'
);

select is(
  (select count(*)::int from public.moderation_actions
    where target_type = 'report' and target_id = '22222222-0000-0000-0000-000000000002'),
  1,
  'one hide, one audit row'
);

select is(
  (select actor_id from public.moderation_actions
    where target_type = 'report' and target_id = '22222222-0000-0000-0000-000000000002'),
  '11111111-0000-0000-0000-000000000003'::uuid,
  'the row records the hand'
);

-- ── The flags that named it ─────────────────────────────────────────────────────────
-- Hiding answers every open flag against the row, in the same transaction. Without this a
-- moderator hides something and the people who reported it are never told.

select is(
  (select count(*)::int from public.flags
    where subject_id = '22222222-0000-0000-0000-000000000002' and status = 'actioned'),
  2,
  'both flags against it are closed as actioned'
);

select is(
  (select count(*)::int from public.moderation_actions where action = 'resolve_flag'),
  2,
  'and each closure is its own audit row, so the log still says who closed what'
);

-- ── The sentence reaches people ─────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000002'),
  3,
  'three notices: one to the author, one to each of the two people who flagged it'
);

select is(
  (select explanation from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000002'
      and recipient_id = '11111111-0000-0000-0000-000000000001'),
  'The transcript reproduces a referee report, which is not yours to publish.'::text,
  'the author gets the sentence the moderator wrote, not a paraphrase'
);

select is(
  (select recipient_role::text from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000002'
      and recipient_id = '11111111-0000-0000-0000-000000000002'),
  'flagger'::text,
  'and whoever flagged it gets the same one, marked as the answer to their flag'
);

select is(
  (select outcome::text from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000002'
      and recipient_id = '11111111-0000-0000-0000-000000000002'),
  'hidden'::text,
  'saying what was decided'
);

select is(
  (select label from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000002'
      and recipient_role = 'author'),
  'Already in the corpus'::text,
  'and naming the post, so a notice is readable without opening anything'
);

-- Who may read one. This is the whole reason the table exists rather than the log being
-- opened up: the log names the moderator and is written to other moderators.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select is(
  (select count(*)::int from public.moderation_notices),
  1,
  'the author reads the decision about their own post and nothing else'
);

select is(
  (select count(*)::int from public.moderation_actions),
  0,
  'and still cannot read the log, which is written to other moderators'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select is(
  (select count(*)::int from public.moderation_notices),
  0,
  'somebody uninvolved reads none of it'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select cmp_ok(
  (select count(*)::int from public.moderation_notices),
  '>=',
  3,
  'a moderator reads them all, so a second moderator can see what the first one said'
);

reset role;

-- ── An author may act on it ─────────────────────────────────────────────────────────
-- Hidden is the one editable state. A hide that could not be answered is a wall, and the
-- published freeze is what it always was, for the reason it always was.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports
   set transcript_excerpt = 'Removed the quoted report; the rest of the session stands.'
 where id = '22222222-0000-0000-0000-000000000002';

-- Editing a published one is an error rather than a silent no-op, and the difference is
-- worth stating: no policy accepts the resulting row at all, so row level security refuses
-- the statement. A guard reverting a column would have succeeded and changed nothing.
select throws_ok(
  $$ update public.reports set title = 'Rewriting history'
      where id = '22222222-0000-0000-0000-000000000001' $$,
  '42501'::text, null::text,
  'and cannot touch one somebody has confirmed: their answer attests to a version'
);

-- Nor is hidden a way to publish yourself. The guard reverts status before row level
-- security sees the row, so the WITH CHECK passes on a row that is still hidden.
update public.reports set status = 'published'
 where id = '22222222-0000-0000-0000-000000000002';

reset role;

select is(
  (select transcript_excerpt from public.reports
    where id = '22222222-0000-0000-0000-000000000002'),
  'Removed the quoted report; the rest of the session stands.'::text,
  'the author revises their hidden report, which is what the explanation asked for'
);

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  'hidden'::text,
  'revising does not republish: that decision is still a moderator''s, and still logged'
);

-- ── Unhiding ────────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'unhide') $$,
  '23514'::text, null::text,
  'putting something back needs a sentence too: the author is told either way'
);

select lives_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000002', 'unhide',
                            'The quoted material is gone. Back in the corpus.') $$,
  'a moderator restores it'
);

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  'published'::text,
  'and it is readable again'
);

select is(
  (select outcome::text from public.moderation_notices
    where action_id = (select id from public.moderation_actions
                        where action = 'unhide' order by created_at desc limit 1)),
  'restored'::text,
  'with a notice to its author saying so'
);

-- ── Dismissing a flag ───────────────────────────────────────────────────────────────
-- The answer a flagger disagrees with, and the one place a content author learns a flag
-- existed at all. Both are told; neither is told who raised it.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('flag', '66666666-0000-0000-0000-000000000004', 'dismiss_flag',
                            'Being wrong is not a reason to remove an account of what somebody did. Reply in the thread.') $$,
  'a moderator leaves a flagged report up'
);

reset role;

select is(
  (select status::text from public.flags where id = '66666666-0000-0000-0000-000000000004'),
  'dismissed'::text,
  'the flag is closed as dismissed, which is not the same word as actioned'
);

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000005'),
  'published'::text,
  'and the report stays exactly where it was'
);

select is(
  (select count(*)::int from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000005'),
  2,
  'two notices: the flagger is answered, and the author is told their post was looked at'
);

select is(
  (select outcome::text from public.moderation_notices
    where subject_id = '22222222-0000-0000-0000-000000000005'
      and recipient_role = 'author'),
  'kept'::text,
  'the author''s says the post stays up'
);

-- ── resolve_flag is for something already gone ──────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('flag', '66666666-0000-0000-0000-000000000001', 'resolve_flag',
                            'Dealt with.') $$,
  '23514'::text, null::text,
  'a flag cannot be closed as acted-on while what it named is still on the site'
);

select lives_ok(
  $$ select public.moderate('comment', '44444444-0000-0000-0000-000000000001', 'hide',
                            'Names a pseudonymous contributor.') $$,
  'so the comment is hidden instead'
);

reset role;

select is(
  (select status::text from public.flags where id = '66666666-0000-0000-0000-000000000001'),
  'actioned'::text,
  'which closes the flag against it without a second decision'
);

select is(
  (select author_id from public.comments where id = '44444444-0000-0000-0000-000000000001'),
  '11111111-0000-0000-0000-000000000002'::uuid,
  'and hiding keeps the text and the name, unlike deleting'
);

-- ── Nobody judges their own ─────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000003', 'hide', 'On reflection.') $$,
  '42501'::text, null::text,
  'a moderator cannot hide their own report'
);

select throws_ok(
  $$ select public.moderate('comment', '44444444-0000-0000-0000-000000000002', 'hide',
                            'Second thoughts.') $$,
  '42501'::text, null::text,
  'nor their own comment -- deleting it as its author is a different act'
);

select throws_ok(
  $$ select public.moderate('flag', '66666666-0000-0000-0000-000000000005', 'dismiss_flag',
                            'On reflection, fine.') $$,
  '42501'::text, null::text,
  'nor answer a flag they raised themselves'
);

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000003'),
  'published'::text,
  'the moderator''s own report is read by somebody else, like everybody else''s'
);

-- ── Claims ─────────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('claim', '33333333-0000-0000-0000-000000000003', 'hide',
                            'Two claims in one sentence; ratings on it would mean nothing.') $$,
  'a moderator hides a claim'
);

reset role;

select is(
  (select activated_at from public.claims where id = '33333333-0000-0000-0000-000000000003'),
  null::timestamptz,
  'and hiding drops its activation date, which the CHECK requires'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('claim', '33333333-0000-0000-0000-000000000003', 'unhide',
                            'Reworded by its author into one claim.') $$,
  'and unhiding puts it back'
);

reset role;

select is(
  (select status::text from public.claims where id = '33333333-0000-0000-0000-000000000003'),
  'active'::text,
  'as part of the record rather than into a waiting state that no longer exists'
);

-- ── Automatic promotion is gone with the queue it served ────────────────────────────

select is(
  (select count(*)::int from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname = 'promote_debate'),
  0,
  'the rating-count promotion function is gone: nothing is waiting to be promoted'
);

select is(
  (select count(*)::int from private.settings where key = 'debate_activation_ratings'),
  0,
  'and so is the threshold it read'
);

-- ── The window is bricked up ────────────────────────────────────────────────────────
-- The half of this file that matters most. No policy admits a moderator's UPDATE on
-- somebody else's row, so the statements below match nothing: they succeed, silently,
-- having changed not one row. That is the correct shape — an error here would be
-- indistinguishable from a bug, and public.moderate() is the only route in either way.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

update public.reports set status = 'hidden'
 where id = '22222222-0000-0000-0000-000000000004';

update public.comments set status = 'hidden'
 where id = '44444444-0000-0000-0000-000000000003';

update public.claims set status = 'hidden'
 where id = '33333333-0000-0000-0000-000000000001';

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000004'),
  'published'::text,
  'a moderator cannot hide a report by direct update: the log cannot be stepped around'
);

select is(
  (select status::text from public.comments where id = '44444444-0000-0000-0000-000000000003'),
  'published'::text,
  'nor a comment'
);

select is(
  (select status::text from public.claims where id = '33333333-0000-0000-0000-000000000001'),
  'active'::text,
  'nor a claim'
);

select ok(
  not has_table_privilege('authenticated', 'public.flags', 'UPDATE'),
  'and a flag cannot be closed by direct update: the grant is gone, not just the policy'
);

-- ── Banning ─────────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000002', 'ban',
                            'Repeated attempts to identify a pseudonymous contributor.') $$,
  'a moderator bans a member'
);

select throws_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000004', 'ban',
                            'Disagreed with me.') $$,
  '42501'::text, null::text,
  'but not an account with moderation standing: one compromised session cannot disable the others'
);

select throws_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000003', 'ban',
                            'Testing.') $$,
  '42501'::text, null::text,
  'and not itself'
);

reset role;

select is(
  (select is_banned from public.profiles where id = '11111111-0000-0000-0000-000000000002'),
  true,
  'the ban took effect through the function, where no column grant would have allowed it'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('account', '11111111-0000-0000-0000-000000000002', 'unban',
                            'Two weeks served and an undertaking not to repeat it.') $$,
  'and a ban can be lifted, with its own sentence'
);

reset role;

select is(
  (select is_banned from public.profiles where id = '11111111-0000-0000-0000-000000000002'),
  false,
  'the account is readmitted'
);

-- ── Who reads the log ───────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000004","role":"authenticated"}';

select cmp_ok(
  (select count(*)::int from public.moderation_actions),
  '>',
  8,
  'an admin sees the whole log'
);

reset role;

-- ── Append-only, for everyone ───────────────────────────────────────────────────────
-- Not `set local role`: this runs as the migration role, which owns the table. The trigger
-- refuses it anyway, and that is the point — absent grants stop a browser and stop nothing
-- else.

select throws_ok(
  $$ update public.moderation_actions set reason = 'Something more defensible.' $$,
  '0A000'::text, null::text,
  'the log cannot be edited, not even by the role that owns it'
);

select throws_ok(
  $$ delete from public.moderation_actions $$,
  '0A000'::text, null::text,
  'nor pruned'
);

-- ── Erasure ─────────────────────────────────────────────────────────────────────────
-- Everything below destroys fixtures.

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('account', '77777777-0000-0000-0000-000000000001', 'erase_account') $$,
  '42501'::text, null::text,
  'a moderator cannot erase an account: a ban is reversible and this is not'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ select public.moderate('account', '77777777-0000-0000-0000-000000000009', 'erase_account') $$,
  '23503'::text, null::text,
  'and an admin can only erase an account that asked: the request is the only way in'
);

select lives_ok(
  $$ select public.moderate('account', '77777777-0000-0000-0000-000000000001', 'erase_account') $$,
  'an admin processes a standing erasure request, and needs no sentence for it'
);

reset role;

select is(
  (select count(*)::int from auth.users where id = '11111111-0000-0000-0000-000000000005'),
  0,
  'the account is gone'
);

select is(
  (select count(*)::int from public.deletion_requests
    where id = '77777777-0000-0000-0000-000000000001'),
  0,
  'and so is the request, which would otherwise record that this person asked to be forgotten'
);

select is(
  (select author_id from public.reports where id = '22222222-0000-0000-0000-000000000004'),
  null::uuid,
  'their published report stays in the corpus without a name on it'
);

select is(
  (select count(*)::int from public.moderation_actions
    where action = 'erase_account' and target_id is null),
  1,
  'the log records that an erasure happened and deliberately not whose'
);

-- ── The one exception to append-only ────────────────────────────────────────────────
-- A moderator erasing their own account has to work, and the foreign key does it by nulling
-- actor_id — which reaches the log as an UPDATE. Without the narrow exception in
-- private.refuse_moderation_edit(), the log of a moderator's decisions would make that
-- moderator undeletable.
--
-- The notices they wrote go the other way: they cascade with their recipients, not with
-- their author, because a notice is a message to somebody rather than a record of a hand.

insert into public.deletion_requests (id, user_id)
values ('77777777-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000003');

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000004","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('account', '77777777-0000-0000-0000-000000000002', 'erase_account') $$,
  'a moderator with decisions behind them can still leave'
);

reset role;

select is(
  (select count(*)::int from public.moderation_actions
    where actor_id = '11111111-0000-0000-0000-000000000003'),
  0,
  'their name comes off every decision'
);

select cmp_ok(
  (select count(*)::int from public.moderation_actions),
  '>',
  8,
  'and the decisions themselves stand'
);

select cmp_ok(
  (select count(*)::int from public.moderation_notices),
  '>',
  0,
  'as do the sentences the people they were written to still need'
);

select * from finish();

rollback;
