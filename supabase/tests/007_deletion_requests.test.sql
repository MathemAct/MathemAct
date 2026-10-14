-- Who may file, read, and withdraw a request for account erasure.
--
-- Two things are being defended here and they pull in opposite directions. A request must
-- be trivially easy to file, because a hard erasure path is not an erasure path. And it
-- must be invisible to everyone but the requester and an admin, because "who has asked to
-- leave" is a more sensitive fact than anything else this schema holds -- profiles are
-- public, contributions are public, and this is neither.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(16);

-- A requester, a bystander, and an admin.
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('dddddddd-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'leaving@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('dddddddd-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'staying@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('dddddddd-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'admin@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

-- Set as the table owner, which the profile guard trusts. There is no browser path to this.
update public.profiles set role = 'admin'
 where id = 'dddddddd-0000-0000-0000-000000000003';

-- The shape of the endpoint ------------------------------------------------------------

select ok(
  (select relrowsecurity from pg_class where oid = 'public.deletion_requests'::regclass),
  'row level security is enabled on public.deletion_requests'
);

select ok(
  not has_table_privilege('anon', 'public.deletion_requests', 'SELECT'),
  'anon has no privilege on deletion_requests at all'
);

select ok(
  not has_table_privilege('authenticated', 'public.deletion_requests', 'UPDATE'),
  'nobody can update a request from a browser: status is the operator''s'
);

select ok(
  not has_column_privilege('authenticated', 'public.deletion_requests', 'status', 'INSERT'),
  'and nobody can set status on the way in either'
);

-- Filing ---------------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}';

insert into public.deletion_requests (user_id, note)
values ('dddddddd-0000-0000-0000-000000000001', 'Please delete my two comments outright.');

select is(
  (select count(*)::int from public.deletion_requests),
  1,
  'a signed-in user may file a request, and sees it'
);

select is(
  (select status from public.deletion_requests
    where user_id = 'dddddddd-0000-0000-0000-000000000001'),
  'pending'::text,
  'a new request is pending'
);

-- The WITH CHECK is what makes user_id a fact about the session rather than a form field.
select throws_ok(
  $$ insert into public.deletion_requests (user_id)
     values ('dddddddd-0000-0000-0000-000000000002') $$,
  '42501'::text, null::text,
  'a user cannot file a request on somebody else''s behalf'
);

-- Refused by the column grant, before any policy is consulted.
select throws_ok(
  $$ insert into public.deletion_requests (user_id, status)
     values ('dddddddd-0000-0000-0000-000000000001', 'completed') $$,
  '42501'::text, null::text,
  'a user cannot file a request that is already resolved'
);

select throws_ok(
  $$ insert into public.deletion_requests (user_id, note)
     values ('dddddddd-0000-0000-0000-000000000001', repeat('x', 1001)) $$,
  '23514'::text, null::text,
  'a note longer than the cap is rejected'
);

select throws_ok(
  $$ insert into public.deletion_requests (user_id)
     values ('dddddddd-0000-0000-0000-000000000001') $$,
  '23505'::text, null::text,
  'a second pending request for the same account is refused'
);

reset role;

-- Reading ----------------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000002","role":"authenticated"}';

select is(
  (select count(*)::int from public.deletion_requests),
  0,
  'another member cannot see that someone has asked to leave'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000003","role":"authenticated"}';

select is(
  (select count(*)::int from public.deletion_requests),
  1,
  'an admin sees the queue'
);

reset role;

-- Withdrawing --------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}';

delete from public.deletion_requests
 where user_id = 'dddddddd-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.deletion_requests),
  0,
  'changing your mind removes the request outright, leaving nothing behind'
);

reset role;

-- A resolved request is not the requester's to erase -------------------------------------
-- It records something that already happened to their account, and an operator needs it to
-- stay put long enough to finish the job.

insert into public.deletion_requests (user_id, status, resolved_at)
values ('dddddddd-0000-0000-0000-000000000001', 'completed', now());

set local role authenticated;
set local request.jwt.claims to '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}';

-- Silent no-op rather than an error: the policy makes the row invisible to the DELETE.
delete from public.deletion_requests
 where user_id = 'dddddddd-0000-0000-0000-000000000001';

reset role;

select is(
  (select count(*)::int from public.deletion_requests where status = 'completed'),
  1,
  'a completed request survives an attempt to withdraw it'
);

-- Status and resolution date cannot drift apart -------------------------------------------

select throws_ok(
  $$ insert into public.deletion_requests (user_id, status)
     values ('dddddddd-0000-0000-0000-000000000002', 'completed') $$,
  '23514'::text, null::text,
  'a resolved request must carry the date it was resolved'
);

select throws_ok(
  $$ insert into public.deletion_requests (user_id, resolved_at)
     values ('dddddddd-0000-0000-0000-000000000002', now()) $$,
  '23514'::text, null::text,
  'and a pending one must not'
);

select * from finish();

rollback;
