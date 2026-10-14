-- The badge is derived from a confirmed address and from nothing else.
--
-- Covers the full lifecycle: account created, address confirmed, address later changed.
-- The last case matters most -- a badge that survives a move to a personal address is a
-- badge that lies.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(16);

-- Fixtures. Synthetic ROR identifiers; see 001 for why.
insert into private.ror_institutions (ror_id, name, country_code, country_name) values
  ('0oxford01', 'University of Oxford', 'GB', 'United Kingdom'),
  ('0unibonn1', 'University of Bonn',   'DE', 'Germany');

insert into private.ror_domains (domain, ror_id) values
  ('ox.ac.uk',    '0oxford01'),
  ('uni-bonn.de', '0unibonn1');

-- A new, unconfirmed account ----------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '11111111-1111-1111-1111-111111111111',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'someone@maths.ox.ac.uk',
  '{}'::jsonb, '{}'::jsonb, now(), now()
);

select is(
  (select count(*)::int from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  1,
  'a profile appears as soon as the account does'
);

select is(
  (select display_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'Member 11111111'::text,
  'the default display name is derived from the account id, never from the address'
);

select is(
  (select institution_ror_id from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null::text,
  'an unconfirmed account has no institution, even at an institutional domain'
);

select is(
  (select institution_verified_at from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null::timestamptz,
  'and no verification date'
);

-- Confirming the address issues the badge ---------------------------------------------

update auth.users
   set email_confirmed_at = now()
 where id = '11111111-1111-1111-1111-111111111111';

select is(
  (select institution_ror_id from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  '0oxford01'::text,
  'confirming an institutional address resolves the subdomain to Oxford'
);

select is(
  (select institution_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'University of Oxford'::text,
  'the institution name is copied onto the profile as a snapshot'
);

select is(
  (select institution_country from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'United Kingdom'::text,
  'as is the country'
);

select isnt(
  (select institution_verified_at from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null::timestamptz,
  'the verification date is recorded, because a badge attests to a check on a date'
);

select is(
  (select institution_source from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'ror_domain'::text,
  'the layer that supplied the domain is recorded, so a bad one can be found later'
);

-- A consumer address earns nothing ----------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '22222222-2222-2222-2222-222222222222',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'someone@gmail.com',
  '{}'::jsonb, jsonb_build_object('display_name', 'Ramanujan'), now(), now()
);

update auth.users
   set email_confirmed_at = now()
 where id = '22222222-2222-2222-2222-222222222222';

select is(
  (select institution_ror_id from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  null::text,
  'a confirmed consumer address gets no institution'
);

select is(
  (select display_name from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'Ramanujan'::text,
  'a display name supplied at signup is used, and a pseudonym is perfectly acceptable'
);

-- Changing a confirmed address re-derives the badge -----------------------------------
-- Without this, the sequence "confirm at a university, then move the account to a
-- personal address" would leave the badge in place forever.

-- A different consumer address from the one the second account holds: auth.users carries
-- a partial unique index on email.
update auth.users
   set email = 'moved-on@gmail.com'
 where id = '11111111-1111-1111-1111-111111111111';

select is(
  (select institution_ror_id from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null::text,
  'moving a confirmed account to a consumer address revokes the badge'
);

select is(
  (select institution_verified_at from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null::timestamptz,
  'and clears the verification date with it'
);

select is(
  (select institution_source from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null::text,
  'and the provenance with it'
);

-- The reverse direction also works: an account that started on a consumer address and
-- moves to an institutional one earns the badge without having to sign up again.
update auth.users
   set email = 'someone@uni-bonn.de'
 where id = '22222222-2222-2222-2222-222222222222';

select is(
  (select institution_name from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'University of Bonn'::text,
  'moving to an institutional address issues the badge'
);

-- Deleting the account removes the profile --------------------------------------------

delete from auth.users where id = '22222222-2222-2222-2222-222222222222';

select is(
  (select count(*)::int from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  0,
  'deleting the account cascades to the profile, so erasure actually erases'
);

select * from finish();

rollback;
