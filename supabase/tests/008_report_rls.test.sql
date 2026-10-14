-- Who may read and write a report.
--
-- Every rule is asserted from both directions. A policy test that only checks the allowed
-- case proves the feature works and says nothing about whether it is a door: the negative
-- assertions below are the ones that would fail if a policy were loosened, and they are
-- the reason this file is longer than the migration it tests.
--
-- Two behaviours here look like bugs and are not, so they are asserted explicitly rather
-- than left for someone to rediscover:
--
--   An author republishing their own hidden report succeeds and changes nothing. The guard
--   trigger reverts `status` before row level security evaluates the new row, so the WITH
--   CHECK then passes on a row that is still hidden. A silent revert, matching how
--   public.profiles already behaves.
--
--   An author editing their own *answered* report raises 42501. Here no policy's USING
--   clause admits the row for a text edit, and reports_soft_delete_own — the one that does
--   admit it — has a WITH CHECK requiring the result to be deleted, which it is not.
--
-- Since post-moderation the editable state is `hidden` rather than `pending`, and nothing
-- is born pending at all. The fixture below keeps one pending row on purpose: rows written
-- before that change still exist, and the read policies have to keep hiding them.
--
-- Fixtures are created as the table owner, which the guards trust. Every assertion runs
-- under `set local role`, because what is being tested is what a browser can do.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(31);

-- ── People ──────────────────────────────────────────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'author@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'bystander@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'unconfirmed@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'banned@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'moderator@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

-- Everyone but the third confirms their address, which is what sets profiles.confirmed_at.
update auth.users set email_confirmed_at = now()
 where id <> '11111111-0000-0000-0000-000000000003';

update public.profiles set is_banned = true
 where id = '11111111-0000-0000-0000-000000000004';

update public.profiles set role = 'moderator'
 where id = '11111111-0000-0000-0000-000000000005';

-- Confirming the fixtures are what they claim to be, before anything is asserted about
-- them. A test suite where the setup silently failed reports a great many passes.
select is(
  (select count(*)::int from public.profiles where confirmed_at is not null),
  4,
  'four of the five fixtures have a confirmed account'
);

-- ── Reports ─────────────────────────────────────────────────────────────────────────

insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed, deleted_at, deleted_by
) values
  ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'published', 'Check a lemma with a proof assistant', 'research', 'proof_checking',
   'Confirm a lemma I could not see a gap in.', 'Stated it in Lean and closed the goals.',
   'worked', 'It found a missing hypothesis.', 'Lean accepted the proof.', true, null, null),

  -- Hidden, which is the one state its author may still edit. Written out rather than
  -- defaulted, unlike the insert further down, because this row is the subject of the edit
  -- assertions and its state is the point of them.
  ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
   'hidden', 'Draft an exposition of a spectral sequence', 'writing', 'exposition',
   'Produce a readable account for a seminar.', 'Asked for a draft, then rewrote it.',
   'partial', 'Structure was usable, details were not.', 'Checked every claim by hand.',
   true, null, null),

  -- A leftover from before post-moderation. Nothing writes this status now, and anon must
  -- still see nothing of it.
  ('22222222-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001',
   'pending', 'A report left over from the approval queue', 'research', 'other',
   'Something.', 'Something else.', 'failed', 'It did not work.',
   'Checked against a textbook.', true, null, null),

  ('22222222-0000-0000-0000-000000000004', '11111111-0000-0000-0000-000000000001',
   'published', 'A report its author has deleted', 'research', 'other',
   'Something.', 'Something else.', 'worked', 'It worked.',
   'Checked by hand.', true, now(), '11111111-0000-0000-0000-000000000001'),

  ('22222222-0000-0000-0000-000000000005', '11111111-0000-0000-0000-000000000002',
   'published', 'Search the literature for a counterexample', 'research', 'literature_search',
   'Find whether the statement is already known false.', 'Asked for references, checked each.',
   'partial', 'Two of five references were invented.', 'Looked up every reference on MathSciNet.',
   true, null, null);

-- What freezes the first one. A published report with nothing attached to it is still its
-- author's to correct — that is the editing rule since post-moderation — so the assertion
-- that a published report cannot be rewritten needs a report somebody has answered.
insert into public.report_confirmations (report_id, user_id, verdict)
values ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000002',
        'still_works');

-- ── Reading ─────────────────────────────────────────────────────────────────────────

set local role anon;

select is(
  (select count(*)::int from public.reports),
  2,
  'anon sees only published, undeleted reports'
);

select is_empty(
  $$ select id from public.reports where status <> 'published' $$,
  'anon sees nothing hidden, and nothing left in the retired pending state'
);

select is_empty(
  $$ select id from public.reports where deleted_at is not null $$,
  'anon sees nothing soft-deleted, even though it is published'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

select is(
  (select count(*)::int from public.reports),
  2,
  'another member sees the published corpus and no more'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select is(
  (select count(*)::int from public.reports),
  5,
  'an author sees their own work in every state, plus the published corpus'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select is(
  (select count(*)::int from public.reports),
  5,
  'a moderator sees everything, including deleted rows a flag might be about'
);

reset role;

-- ── Writing: who may post at all ────────────────────────────────────────────────────

set local role anon;

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('11111111-0000-0000-0000-000000000001', 'From nowhere', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'anon cannot post a report'
);

reset role;

-- The account exists and is signed in; it has simply never confirmed its address. This is
-- the case profiles.confirmed_at was added for.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('11111111-0000-0000-0000-000000000003', 'Unconfirmed', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'an unconfirmed account cannot post'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('11111111-0000-0000-0000-000000000004', 'Banned', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'a banned account cannot post'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('11111111-0000-0000-0000-000000000001', 'Under a false name', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'a member cannot post under somebody else''s name'
);

-- Refused by the column grant, before any policy is consulted. It reads oddly now that the
-- default *is* 'published' — but the rule it protects has not moved: what a browser may
-- write into `status` is nothing at all, in either direction, so nobody can post something
-- already hidden either, and the day the default changes again this stays true.
select throws_ok(
  $$ insert into public.reports
       (author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('11111111-0000-0000-0000-000000000002', 'hidden', 'Born hidden',
             'research', 'other', 'a', 'b', 'worked', 'c', 'd', true) $$,
  '42501'::text, null::text,
  'nobody can name status when posting: it has no INSERT grant in either direction'
);

-- The allowed case. No `id` in the column list, because it has no INSERT grant either:
-- the row identifies itself. A client that needs the new id asks for it back.
insert into public.reports
  (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
   verification, third_party_material_confirmed)
values ('11111111-0000-0000-0000-000000000002',
        'A perfectly ordinary submission', 'learning', 'proof_drafting',
        'Understand a proof I had been stuck on.', 'Asked for the outline, filled it in.',
        'worked', 'The outline was right.', 'Rederived every step myself.', true);

reset role;

select is(
  (select status::text from public.reports
    where title = 'A perfectly ordinary submission'),
  'published'::text,
  'a confirmed member may post, and what they post is in the corpus at once'
);

-- ── Writing: editing your own ───────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports
   set title = 'Draft an exposition of a spectral sequence, revised'
 where id = '22222222-0000-0000-0000-000000000002';

reset role;

select is(
  (select title from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  'Draft an exposition of a spectral sequence, revised'::text,
  'an author may edit their own report while it is hidden, which is how a hide gets answered'
);

-- Publishing your own. Succeeds, and changes nothing: the guard reverts status before row
-- level security sees the row, so the WITH CHECK passes on a row that is still hidden.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports set status = 'published'
 where id = '22222222-0000-0000-0000-000000000002';

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  'hidden'::text,
  'an author cannot lift a hide on their own report; the guard reverts it silently'
);

-- Editing a published one. No policy accepts the resulting row, so this is an error rather
-- than a silent no-op.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ update public.reports set title = 'Rewriting history'
      where id = '22222222-0000-0000-0000-000000000001' $$,
  '42501'::text, null::text,
  'an author cannot edit their own report once somebody has confirmed or commented on it'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000002","role":"authenticated"}';

update public.reports set title = 'Hijacked'
 where id = '22222222-0000-0000-0000-000000000001';

reset role;

select isnt(
  (select title from public.reports where id = '22222222-0000-0000-0000-000000000001'),
  'Hijacked'::text,
  'a member cannot edit somebody else''s report'
);

-- ── Soft deletion ───────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports
   set deleted_at = now(), deleted_by = '11111111-0000-0000-0000-000000000001'
 where id = '22222222-0000-0000-0000-000000000001';

reset role;

select isnt(
  (select deleted_at from public.reports where id = '22222222-0000-0000-0000-000000000001'),
  null::timestamptz,
  'an author may soft-delete their own report after it is published'
);

-- Restoring is a moderation action. No policy's USING clause matches a deleted row for its
-- author, so this is a silent no-op rather than an error.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports set deleted_at = null, deleted_by = null
 where id = '22222222-0000-0000-0000-000000000001';

reset role;

select isnt(
  (select deleted_at from public.reports where id = '22222222-0000-0000-0000-000000000001'),
  null::timestamptz,
  'an author cannot restore a report they deleted'
);

-- ── Moderation ──────────────────────────────────────────────────────────────────────
-- There is no moderator UPDATE policy on this table. Since 20260815200300 every decision
-- goes through public.moderate(), which writes an audit row in the same transaction, and
-- the direct update that used to do the same job matches no policy and so changes nothing.
-- Both halves are asserted here, because a suite that checked only the first would still
-- pass on the day somebody re-adds the policy "so the queue can be fixed quickly".

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate(
       'report',
       (select id from public.reports where title = 'A perfectly ordinary submission'),
       'hide',
       'Third-party material in the transcript.') $$,
  'a moderator may hide a report, through the audited path'
);

reset role;

select is(
  (select status::text from public.reports
    where title = 'A perfectly ordinary submission'),
  'hidden'::text,
  'and it is hidden'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate('report', '22222222-0000-0000-0000-000000000005', 'hide',
                            'Reproduces an unpublished referee report.') $$,
  'a moderator may hide a published report: the hide path works'
);

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000005'),
  'hidden'::text,
  'and it is hidden'
);

-- The same moderator, the same row, the unaudited way. No policy admits it, so it succeeds
-- having changed nothing rather than raising — which is the correct shape here: an error
-- would be indistinguishable from a bug, and the queue is the only route in either way.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

update public.reports set status = 'published'
 where id = '22222222-0000-0000-0000-000000000005';

reset role;

select is(
  (select status::text from public.reports where id = '22222222-0000-0000-0000-000000000005'),
  'hidden'::text,
  'a direct update by a moderator changes nothing: the audit log cannot be stepped around'
);

-- Nobody is ever an author but the author. Reassigning a contribution would put somebody
-- else's name on work published under CC BY, so it is locked twice: no column grant, and a
-- guard that reverts it anyway. Both are asserted, because the second exists precisely for
-- the day somebody widens the first. The column check runs before row level security, so
-- this raises for the moderator even though no policy would have matched the row.
set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select throws_ok(
  $$ update public.reports set author_id = '11111111-0000-0000-0000-000000000005'
      where id = '22222222-0000-0000-0000-000000000005' $$,
  '42501'::text, null::text,
  'not even a moderator can reassign a report: author_id has no column grant'
);

reset role;

-- The realistic accident: somebody adding a feature writes `grant update on
-- public.reports to authenticated` because the column list was in the way. The author's
-- own pending report is the row to try it on, because that is the one case where a
-- policy does accept the update and only the guard stands between the grant and the harm.
grant update on public.reports to authenticated;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.reports set author_id = '11111111-0000-0000-0000-000000000002'
 where id = '22222222-0000-0000-0000-000000000002';

reset role;

select is(
  (select author_id from public.reports where id = '22222222-0000-0000-0000-000000000002'),
  '11111111-0000-0000-0000-000000000001'::uuid,
  'and the guard reverts it even with the column grant wide open'
);

-- ── No hard delete, for anyone ──────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ delete from public.reports where id = '22222222-0000-0000-0000-000000000002' $$,
  '42501'::text, null::text,
  'an author cannot hard-delete their own report'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-0000-0000-0000-000000000005","role":"authenticated"}';

select throws_ok(
  $$ delete from public.reports where id = '22222222-0000-0000-0000-000000000001' $$,
  '42501'::text, null::text,
  'nor can a moderator: there is no DELETE grant on this table at all'
);

reset role;

select ok(
  not has_table_privilege('authenticated', 'public.reports', 'DELETE'),
  'the absent DELETE grant is the reason, not an absent policy'
);

-- ── Erasure detaches rather than destroys ───────────────────────────────────────────
-- The account goes; the contribution stays in the corpus without a name on it. This is the
-- promise the privacy notice makes, and ON DELETE SET NULL is the whole of its
-- implementation.

delete from auth.users where id = '11111111-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.reports where id = '22222222-0000-0000-0000-000000000005'),
  1,
  'erasing an account leaves the reports it contributed in place'
);

select is(
  (select author_id from public.reports where id = '22222222-0000-0000-0000-000000000005'),
  null::uuid,
  'and strips the attribution from them'
);

select * from finish();

rollback;
