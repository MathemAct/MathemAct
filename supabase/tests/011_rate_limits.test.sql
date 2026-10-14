-- The floor under the moderation queue.
--
-- Not spam defence -- Turnstile and mandatory email confirmation do that at the door. This
-- is what stops one account putting two hundred reports in front of a volunteer
-- overnight, whether through malice, a misfiring script, or somebody finding the API and
-- testing it thoroughly.
--
-- Three properties are asserted, and the third is the one worth having a test for: the
-- limit counts rows the caller cannot see, it cannot be read from a browser, and an
-- unconfigured limit refuses rather than waves everything through.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(8);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('77777777-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'prolific@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('77777777-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'quiet@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

-- Lowered so the test is three inserts rather than eleven. The threshold being a row is
-- exactly why this is one statement.
update private.settings set value = '2' where key = 'rate_limit_reports_per_day';
update private.settings set value = '2' where key = 'rate_limit_confirmations_per_day';

-- ── The limit itself is not reachable ───────────────────────────────────────────────

select ok(
  not has_table_privilege('authenticated', 'private.settings', 'SELECT'),
  'a member cannot read the limit they are subject to'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"77777777-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ select value from private.settings where key = 'rate_limit_reports_per_day' $$,
  '42501'::text, null::text,
  'and cannot reach private.settings at all'
);

reset role;

-- ── Reports ─────────────────────────────────────────────────────────────────────────
-- The two rows that fill the quota are inserted as the table owner, which lets them carry
-- explicit ids for the confirmations below to point at -- `id` has no INSERT grant, so a
-- browser role cannot name it. The limiter is a plain BEFORE INSERT trigger with no notion
-- of who the caller is, so it counts these exactly as it counts anyone's.

insert into public.reports
  (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
   verification, third_party_material_confirmed)
values
  ('88888888-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001',
   'First', 'research', 'other', 'a', 'b', 'worked', 'c', 'd', true),
  ('88888888-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000001',
   'Second', 'research', 'other', 'a', 'b', 'worked', 'c', 'd', true);

select is(
  (select count(*)::int from public.reports
    where author_id = '77777777-0000-0000-0000-000000000001'),
  2,
  'an author may post up to the configured limit'
);

set local role authenticated;
set local request.jwt.claims to '{"sub":"77777777-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('77777777-0000-0000-0000-000000000001', 'Third', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '53400'::text, null::text,
  'and is refused the one past it'
);

reset role;

-- The count is of everything the author has written, not of what they can still see. As
-- SECURITY INVOKER the function would miss a hidden row, which would make the quickest
-- route past the limit be to get moderated.
update public.reports set status = 'hidden'
 where id = '88888888-0000-0000-0000-000000000001';

set local role authenticated;
set local request.jwt.claims to '{"sub":"77777777-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('77777777-0000-0000-0000-000000000001', 'Third again', 'research', 'other',
             'a', 'b', 'worked', 'c', 'd', true) $$,
  '53400'::text, null::text,
  'having a report hidden does not free up a slot'
);

reset role;

-- The limit is per author, not global. One enthusiastic account must not stop everyone
-- else from posting.
insert into public.reports
  (id, author_id, title, area, task_type, aim, method, outcome, outcome_notes,
   verification, third_party_material_confirmed)
values ('88888888-0000-0000-0000-000000000003', '77777777-0000-0000-0000-000000000002',
        'Somebody else entirely', 'research', 'other', 'a', 'b', 'worked', 'c', 'd', true);

select is(
  (select count(*)::int from public.reports where author_id = '77777777-0000-0000-0000-000000000002'),
  1,
  'the limit is per author: another member is unaffected'
);

-- ── Confirmations ───────────────────────────────────────────────────────────────────

update public.reports set status = 'published';

insert into public.report_confirmations (report_id, user_id, verdict) values
  ('88888888-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000002', 'still_works'),
  ('88888888-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000002', 'still_works');

set local role authenticated;
set local request.jwt.claims to '{"sub":"77777777-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.report_confirmations (report_id, user_id, verdict)
     values ('88888888-0000-0000-0000-000000000003',
             '77777777-0000-0000-0000-000000000002', 'still_works') $$,
  '53400'::text, null::text,
  'confirmations are limited on the same rolling window'
);

reset role;

-- ── An unknown limit is a refusal, not permission ───────────────────────────────────
-- Everything in the function is written so that the failure mode is a refused insert. A
-- missing row here would otherwise read as "no limit configured, therefore no limit".

delete from private.settings where key = 'rate_limit_reports_per_day';

set local role authenticated;
set local request.jwt.claims to '{"sub":"77777777-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.reports
       (author_id, title, area, task_type, aim, method, outcome, outcome_notes,
        verification, third_party_material_confirmed)
     values ('77777777-0000-0000-0000-000000000002', 'With no limit configured', 'research',
             'other', 'a', 'b', 'worked', 'c', 'd', true) $$,
  '53400'::text, null::text,
  'a missing threshold refuses the insert rather than removing the limit'
);

reset role;

select * from finish();

rollback;
