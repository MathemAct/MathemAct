-- What the signup form is allowed to put in a profile.
--
-- raw_user_meta_data is whatever the browser sent. handle_new_user reads exactly two keys
-- out of it, and both name columns the user could write anyway. These assertions are less
-- about the two keys working than about the other keys not: the failure this guards
-- against is a future edit that copies the object wholesale and hands out an admin role to
-- anyone who can open a network tab.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(10);

-- Six accounts, one per signup shape. Distinct addresses throughout: auth.users carries a
-- partial unique index on email, so two fixtures cannot share one.
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  -- A pseudonym, requested as a JSON boolean, which is what supabase-js sends.
  ('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'one@example.org', '{}'::jsonb,
   '{"display_name":"A. Reader","is_pseudonym":true}'::jsonb, now(), now()),

  -- The same request as a string, which is what a hand-rolled fetch or a form encoder
  -- sends. Both must mean the same thing.
  ('aaaaaaaa-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'two@example.org', '{}'::jsonb,
   '{"display_name":"B. Reader","is_pseudonym":"true"}'::jsonb, now(), now()),

  -- Nothing said about pseudonymity.
  ('aaaaaaaa-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'three@example.org', '{}'::jsonb,
   '{"display_name":"C. Reader"}'::jsonb, now(), now()),

  -- Garbage where a boolean should be. This must produce a profile, not an exception: a
  -- cast here would turn a malformed field into a failed signup.
  ('aaaaaaaa-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'four@example.org', '{}'::jsonb,
   '{"display_name":"D. Reader","is_pseudonym":"probably"}'::jsonb, now(), now()),

  -- The attack. Every key here names a system-owned column.
  ('aaaaaaaa-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'five@example.org', '{}'::jsonb,
   '{"display_name":"E. Reader","role":"admin","is_banned":false,'
   '"institution_name":"University of Oxford","institution_ror_id":"0oxford01"}'::jsonb,
   now(), now()),

  -- No display name at all, and a local part that would be a give-away if it were used.
  ('aaaaaaaa-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'wilhelmina.brouwer@example.org', '{}'::jsonb,
   '{"display_name":"   "}'::jsonb, now(), now());

-- The two keys that are read ----------------------------------------------------------

select is(
  (select display_name from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'A. Reader'::text,
  'the display name from signup metadata reaches the profile'
);

select is(
  (select is_pseudonym from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  true,
  'a JSON boolean pseudonym preference is honoured'
);

select is(
  (select is_pseudonym from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  true,
  'and so is the same preference sent as a string'
);

select is(
  (select is_pseudonym from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000003'),
  false,
  'saying nothing about pseudonymity means no pseudonym'
);

select is(
  (select is_pseudonym from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000004'),
  false,
  'an unparseable pseudonym preference means no pseudonym, and does not fail the signup'
);

-- Everything else is ignored ----------------------------------------------------------

select is(
  (select role from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000005'),
  'member'::text,
  'a role asked for in signup metadata is ignored'
);

select is(
  (select is_banned from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000005'),
  false,
  'is_banned in signup metadata is ignored'
);

select is(
  (select institution_name from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000005'),
  null::text,
  'an institution asked for in signup metadata is ignored'
);

-- The fallback name -------------------------------------------------------------------

select alike(
  (select display_name from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000006'),
  'Member %'::text,
  'a blank display name falls back to one derived from the account id'
);

select unalike(
  (select display_name from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000006'),
  '%wilhelmina%'::text,
  'and never to the local part of the email address'
);

select * from finish();

rollback;
