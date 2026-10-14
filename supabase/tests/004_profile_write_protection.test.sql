-- Who may write what to public.profiles.
--
-- The system-owned columns are protected twice: by column-level UPDATE grants, and by a
-- BEFORE UPDATE trigger that reverts them. Both are tested here, and the second is tested
-- with the grants deliberately widened, because the whole point of the trigger is to hold
-- when someone loosens a grant while adding a feature.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(14);

insert into private.ror_institutions (ror_id, name, country_code, country_name)
values ('0oxford01', 'University of Oxford', 'GB', 'United Kingdom');
insert into private.ror_domains (domain, ror_id) values ('ox.ac.uk', '0oxford01');

-- Two accounts: a verified Oxford member, and a bystander.
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'member@maths.ox.ac.uk', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'other@gmail.com', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

-- Anonymous callers cannot write at all -----------------------------------------------

set local role anon;

select throws_ok(
  $$ update public.profiles set display_name = 'anon was here' $$,
  '42501'::text, null::text,
  'anon cannot update any profile'
);

select throws_ok(
  $$ insert into public.profiles (id, display_name) values (gen_random_uuid(), 'ghost') $$,
  '42501'::text, null::text,
  'anon cannot insert a profile'
);

select throws_ok(
  $$ delete from public.profiles $$,
  '42501'::text, null::text,
  'anon cannot delete a profile'
);

reset role;

-- A signed-in user, with the grants as shipped ----------------------------------------

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- The column grant rejects these outright, before any trigger runs.
select throws_ok(
  $$ update public.profiles set role = 'admin' where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501'::text, null::text,
  'a signed-in user cannot write role: no column grant'
);

select throws_ok(
  $$ update public.profiles set is_banned = false where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501'::text, null::text,
  'a signed-in user cannot write is_banned: no column grant'
);

select throws_ok(
  $$ update public.profiles set institution_name = 'Institute for Advanced Study'
      where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501'::text, null::text,
  'a signed-in user cannot write institution_name: no column grant'
);


-- What they may do.
update public.profiles
   set display_name = 'A. Mathematician', bio = 'Analytic number theory.', is_pseudonym = true
 where id = '11111111-1111-1111-1111-111111111111';

select is(
  (select display_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'A. Mathematician'::text,
  'a signed-in user may change their own display name'
);

-- Row level security keeps them off other people's rows. This is a silent no-op rather
-- than an error: the policy makes the row invisible to the UPDATE.
update public.profiles set display_name = 'hijacked'
 where id = '22222222-2222-2222-2222-222222222222';

select isnt(
  (select display_name from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'hijacked'::text,
  'a signed-in user cannot change someone else''s profile'
);

reset role;

-- The trigger holds even with the grants widened --------------------------------------
-- Simulating the realistic accident: someone adds a feature and writes
-- `grant update on public.profiles to authenticated` because the column list was in the
-- way. Every system-owned column must still be reverted.

grant update on public.profiles to authenticated;

set local role authenticated;
set local request.jwt.claims to '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

update public.profiles
   set role                    = 'admin',
       is_banned               = false,
       institution_ror_id      = '0oxford01',
       institution_name        = 'Institute for Advanced Study',
       institution_country     = 'United States',
       institution_verified_at = now(),
       institution_source      = 'manual',
       display_name            = 'Still Me'
 where id = '11111111-1111-1111-1111-111111111111';

reset role;

select is(
  (select institution_source from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'ror_domain'::text,
  'the trigger reverts a self-declared provenance too'
);

select is(
  (select role from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'member'::text,
  'the trigger reverts role even when the column grant is wide open'
);

select is(
  (select institution_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'University of Oxford'::text,
  'the trigger reverts a self-declared institution to the derived one'
);

select is(
  (select institution_country from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'United Kingdom'::text,
  'and the country with it'
);


select is(
  (select display_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'Still Me'::text,
  'while the user-owned columns in the same statement still take effect'
);

-- An account with no institution cannot acquire one by writing to it ------------------
-- The account on a consumer address has null institution columns. Setting all four at
-- once satisfies the all-or-nothing constraint, so only the trigger stands between this
-- user and a fabricated badge.

set local role authenticated;
set local request.jwt.claims to '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

update public.profiles
   set institution_ror_id      = '0oxford01',
       institution_name        = 'University of Oxford',
       institution_country     = 'United Kingdom',
       institution_verified_at = now()
 where id = '22222222-2222-2222-2222-222222222222';

reset role;

select is(
  (select institution_ror_id from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  null::text,
  'a user on a consumer address cannot award themselves a badge, grants notwithstanding'
);

select * from finish();

rollback;
