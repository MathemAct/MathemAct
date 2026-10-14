-- Who may read and write an entry, and what the URL deduplication does.
--
-- The same two-direction discipline as 008_report_rls.test.sql: every allowed case
-- is verified, and every forbidden case is verified too. The negative assertions are the
-- ones that would fail the day a policy is loosened.
--
-- Two behaviours that look like bugs and are not:
--
--   An author self-publishing succeeds and changes nothing. The guard reverts status
--   before RLS evaluates the new row, so the WITH CHECK passes on a still-pending row.
--
--   An author editing their own published entry raises 42501. The guard reverts the
--   text but leaves deleted_at null, and no policy's WITH CHECK accepts that row.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(34);

-- ── People ──────────────────────────────────────────────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('33331111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'res_submitter@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('33331111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'res_bystander@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('33331111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'res_unconfirmed@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('33331111-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'res_banned@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('33331111-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'res_moderator@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  -- Posts nothing in the fixtures, and exists only for the column-constraint tests below.
  -- They need five or six inserts between them and every other confirmed account here is
  -- close enough to the five-per-day limit that the CHECK they are testing never gets
  -- evaluated: enforce_daily_limit() is a BEFORE INSERT trigger, so it raises 53400 first
  -- and a test expecting 23514 fails for a reason that has nothing to do with the column.
  ('33331111-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'res_schema@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id <> '33331111-0000-0000-0000-000000000003';

update public.profiles set is_banned = true
 where id = '33331111-0000-0000-0000-000000000004';

update public.profiles set role = 'moderator'
 where id = '33331111-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.profiles where confirmed_at is not null),
  5,
  'five of the six fixtures have a confirmed account'
);

-- ── Network ──────────────────────────────────────────────────────────────────────────────

insert into public.network_entries (
  id, submitter_id, status, title, url, url_normalised, category, description, relevance, deleted_at, deleted_by
) values
  -- Published entry, submitter 1
  ('44440000-0000-0000-0000-000000000001', '33331111-0000-0000-0000-000000000001',
   'published', 'Lean 4 documentation', 'https://leanprover.github.io/lean4/doc/',
   private.normalise_url('https://leanprover.github.io/lean4/doc/'),
   'formalisation', 'Official Lean 4 reference.', 'Lean 4 is the proof assistant most used for formalising mathematics in our community.', null, null),

  -- Hidden entry, submitter 1. Hidden is the one state its submitter may still edit, which
  -- is what makes a hide answerable rather than final.
  ('44440000-0000-0000-0000-000000000002', '33331111-0000-0000-0000-000000000001',
   'hidden', 'Draft entry', 'https://example.com/draft',
   private.normalise_url('https://example.com/draft'),
   'reading', 'A draft.', 'Interesting for reasons.', null, null),

  -- A leftover from before post-moderation. Nothing writes this status now, and anon must
  -- still see nothing of it.
  ('44440000-0000-0000-0000-000000000003', '33331111-0000-0000-0000-000000000001',
   'pending', 'Entry left over from the approval queue', 'https://example.com/hidden',
   private.normalise_url('https://example.com/hidden'),
   'community', 'Hidden.', 'Relevant but hidden.', null, null),

  -- Soft-deleted entry, submitter 1
  ('44440000-0000-0000-0000-000000000004', '33331111-0000-0000-0000-000000000001',
   'published', 'Deleted entry', 'https://example.com/deleted',
   private.normalise_url('https://example.com/deleted'),
   'research_tool', 'Deleted.', 'This was deleted.', now(), '33331111-0000-0000-0000-000000000001'),

  -- Published entry, submitter 2
  ('44440000-0000-0000-0000-000000000005', '33331111-0000-0000-0000-000000000002',
   'published', 'ChatGPT for mathematics', 'https://chat.openai.com/',
   private.normalise_url('https://chat.openai.com/'),
   'research_tool', 'OpenAI ChatGPT interface.', 'Widely used in the community.', null, null);

-- ── Reading ─────────────────────────────────────────────────────────────────────────────

set local role anon;

select is(
  (select count(*)::int from public.network_entries),
  2,
  'anon sees only published, undeleted entries'
);

select is_empty(
  $$ select id from public.network_entries where status <> 'published' $$,
  'anon sees nothing hidden, and nothing left in the retired pending state'
);

select is_empty(
  $$ select id from public.network_entries where deleted_at is not null $$,
  'anon sees nothing soft-deleted'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000002","role":"authenticated"}';

select is(
  (select count(*)::int from public.network_entries),
  2,
  'another member sees the published corpus and no more'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

select is(
  (select count(*)::int from public.network_entries),
  5,
  'a submitter sees their own work in every state, plus the published corpus'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000005","role":"authenticated"}';

select is(
  (select count(*)::int from public.network_entries),
  5,
  'a moderator sees everything, including deleted rows'
);

reset role;

-- ── Writing: who may post at all ────────────────────────────────────────────────────────

set local role anon;

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000001', 'From nowhere', 'https://example.com/anon',
             'reading', 'A description.', 'Some relevance.') $$,
  '42501'::text, null::text,
  'anon cannot post an entry'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000003', 'Unconfirmed', 'https://example.com/unconfirmed',
             'reading', 'A description.', 'Some relevance.') $$,
  '42501'::text, null::text,
  'an unconfirmed account cannot post'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000004', 'Banned', 'https://example.com/banned',
             'reading', 'A description.', 'Some relevance.') $$,
  '42501'::text, null::text,
  'a banned account cannot post'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000001', 'Under a false name', 'https://example.com/false-name',
             'reading', 'A description.', 'Some relevance.') $$,
  '42501'::text, null::text,
  'a member cannot post under somebody else''s name'
);

-- The allowed case.
insert into public.network_entries
  (submitter_id, title, url, category, description, relevance)
values ('33331111-0000-0000-0000-000000000002',
        'A perfectly ordinary submission', 'https://example.com/ordinary',
        'educational', 'An educational entry.', 'Useful for mathematicians learning AI tools.');

reset role;

select is(
  (select status::text from public.network_entries where title = 'A perfectly ordinary submission'),
  'published'::text,
  'a confirmed member may post, and what they post is on the network at once'
);

select is(
  (select url_normalised from public.network_entries where title = 'A perfectly ordinary submission'),
  'example.com/ordinary',
  'url_normalised is computed on insert (scheme stripped, lowercase)'
);

-- ── The category_other constraint ────────────────────────────────────────────────────────
-- Submitter 6 throughout: only the successful inserts count against the daily limit, but
-- every account above is near enough to it that the trigger would answer before the CHECK.

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000006","role":"authenticated"}';

select lives_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, category_other, description)
     values ('33331111-0000-0000-0000-000000000006',
             'An other-category entry', 'https://example.com/other-cat',
             'other', 'Symbolic computation', 'A description.') $$,
  'category=other with a category_other string is accepted'
);

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description)
     values ('33331111-0000-0000-0000-000000000006',
             'Other without label', 'https://example.com/other-no-label',
             'other', 'A description.') $$,
  '23514'::text, null::text,
  'category=other without category_other fails the CHECK constraint'
);

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, category_other, description)
     values ('33331111-0000-0000-0000-000000000006',
             'Non-other with label', 'https://example.com/non-other-with-label',
             'community', 'Should be null', 'A description.') $$,
  '23514'::text, null::text,
  'category<>other with a category_other value fails the CHECK constraint'
);

reset role;

-- ── One prose field ──────────────────────────────────────────────────────────────────────
-- `relevance` was retired on 2026-08-21 and the description absorbed it. The column stays,
-- nullable, for the rows submitted while it was collected.

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000006","role":"authenticated"}';

select lives_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description)
     values ('33331111-0000-0000-0000-000000000006',
             'No relevance given', 'https://example.com/no-relevance',
             'reading', 'The description now carries the whole of the prose.') $$,
  'an entry may be submitted with no relevance at all'
);

select lives_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description)
     values ('33331111-0000-0000-0000-000000000006',
             'A long description', 'https://example.com/long-description',
             'reading', repeat('x', 1000)) $$,
  'the description cap is 1000 characters'
);

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description)
     values ('33331111-0000-0000-0000-000000000006',
             'Too long', 'https://example.com/too-long',
             'reading', repeat('x', 1001)) $$,
  '23514'::text, null::text,
  'and 1001 characters is refused'
);

reset role;

-- ── Writing: editing your own ────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.network_entries
   set title = 'Lean 4 documentation, revised'
 where id = '44440000-0000-0000-0000-000000000002';

reset role;

select is(
  (select title from public.network_entries where id = '44440000-0000-0000-0000-000000000002'),
  'Lean 4 documentation, revised'::text,
  'a submitter may edit their own entry while it is hidden'
);

-- Lifting the hide yourself: guard reverts status, WITH CHECK passes on a still-hidden row.
set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.network_entries set status = 'published'
 where id = '44440000-0000-0000-0000-000000000002';

reset role;

select is(
  (select status::text from public.network_entries where id = '44440000-0000-0000-0000-000000000002'),
  'hidden'::text,
  'a submitter cannot lift a hide on their own entry; the guard reverts status silently'
);

-- Editing a published entry.
set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ update public.network_entries set title = 'Rewriting history'
      where id = '44440000-0000-0000-0000-000000000001' $$,
  '42501'::text, null::text,
  'a submitter cannot edit their own entry once it is published'
);

reset role;

-- ── Soft deletion ────────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.network_entries
   set deleted_at = now(), deleted_by = '33331111-0000-0000-0000-000000000001'
 where id = '44440000-0000-0000-0000-000000000001';

reset role;

select isnt(
  (select deleted_at from public.network_entries where id = '44440000-0000-0000-0000-000000000001'),
  null::timestamptz,
  'a submitter may soft-delete their own published entry'
);

-- Restoring: silent no-op (no policy accepts a deleted row for its owner).
set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

update public.network_entries set deleted_at = null, deleted_by = null
 where id = '44440000-0000-0000-0000-000000000001';

reset role;

select isnt(
  (select deleted_at from public.network_entries where id = '44440000-0000-0000-0000-000000000001'),
  null::timestamptz,
  'a submitter cannot restore an entry they deleted (silent no-op)'
);

-- ── Moderation ───────────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000005","role":"authenticated"}';

select lives_ok(
  $$ select public.moderate(
       'entry',
       (select id from public.network_entries where title = 'A perfectly ordinary submission'),
       'hide',
       'A product page rather than something a mathematician can use.') $$,
  'a moderator may hide an entry through the audited path'
);

reset role;

select is(
  (select status::text from public.network_entries where title = 'A perfectly ordinary submission'),
  'hidden'::text,
  'and it is hidden'
);

-- Direct moderator update changes nothing.
set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000005","role":"authenticated"}';

update public.network_entries set status = 'published'
 where title = 'A perfectly ordinary submission';

reset role;

select is(
  (select status::text from public.network_entries where title = 'A perfectly ordinary submission'),
  'hidden'::text,
  'a direct moderator update changes nothing: the audit log cannot be stepped around'
);

-- ── No hard delete ───────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000001","role":"authenticated"}';

select throws_ok(
  $$ delete from public.network_entries where id = '44440000-0000-0000-0000-000000000002' $$,
  '42501'::text, null::text,
  'a submitter cannot hard-delete their own entry'
);

reset role;

select ok(
  not has_table_privilege('authenticated', 'public.network_entries', 'DELETE'),
  'the absent DELETE grant is the reason, not an absent policy'
);

-- ── URL deduplication ────────────────────────────────────────────────────────────────────

-- Submitting the same URL as an existing published entry fails.
set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000002","role":"authenticated"}';

select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000002',
             'ChatGPT again', 'https://chat.openai.com/',
             'research_tool', 'OpenAI.', 'Useful.') $$,
  '23505'::text, null::text,
  'the same URL cannot be submitted twice among non-deleted entries'
);

-- UTM variants are also deduplicated: the normalised URL strips tracking params.
select throws_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000002',
             'ChatGPT with UTM', 'https://chat.openai.com/?utm_source=newsletter',
             'research_tool', 'OpenAI.', 'Useful.') $$,
  '23505'::text, null::text,
  'a UTM-decorated URL of a submitted entry is also rejected'
);

reset role;

-- A deleted entry's URL can be resubmitted.
-- (entry 44440000-0000-0000-0000-000000000004 is already soft-deleted above).
set local role authenticated;
set local request.jwt.claims to '{"sub":"33331111-0000-0000-0000-000000000002","role":"authenticated"}';

select lives_ok(
  $$ insert into public.network_entries
       (submitter_id, title, url, category, description, relevance)
     values ('33331111-0000-0000-0000-000000000002',
             'Deleted URL resubmitted', 'https://example.com/deleted',
             'reading', 'Resubmitted.', 'The original was deleted.') $$,
  'a URL belonging only to a deleted entry may be resubmitted'
);

reset role;

-- ── Erasure detaches ─────────────────────────────────────────────────────────────────────

delete from auth.users where id = '33331111-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.network_entries where id = '44440000-0000-0000-0000-000000000005'),
  1,
  'erasing an account leaves the entries it submitted in place'
);

select is(
  (select submitter_id from public.network_entries where id = '44440000-0000-0000-0000-000000000005'),
  null::uuid,
  'and strips the attribution from them'
);

select * from finish();

rollback;
