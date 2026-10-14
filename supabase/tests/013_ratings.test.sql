-- Claims, ratings, and the aggregate.
--
-- Two properties carry the rest of this file. A rating row is readable only by the person
-- who wrote it, and a NULL score is a real answer rather than an absence. Everything about
-- the aggregate follows from the second: coverage exists because declining is recordable,
-- and the median means something because the people who declined are not in it.
--
-- And one negative that is asserted rather than assumed: nothing anywhere returns a mean.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(30);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('bbbb0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'proposer@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('bbbb0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'rater@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('bbbb0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'nosy@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('bbbb0000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'unconfirmed-p@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now()
 where id <> 'bbbb0000-0000-0000-0000-000000000004';

insert into public.claims (id, author_id, statement, area, status, activated_at)
values
  ('cccc0000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001',
   'AI-assisted literature search should be disclosed in papers.', 'writing', 'active', now()),
  -- A leftover from before post-moderation: nothing is written in this status now, and
  -- ratings still have to attach to it, because the rows exist.
  ('cccc0000-0000-0000-0000-000000000002', 'bbbb0000-0000-0000-0000-000000000001',
   'Formalising a statement before proving it is worth the time it costs.', 'research',
   'proposed', null),
  ('cccc0000-0000-0000-0000-000000000003', 'bbbb0000-0000-0000-0000-000000000001',
   'This claim has been moderated away and nobody should see it.', 'other', 'hidden', null);

-- ── The scale ───────────────────────────────────────────────────────────────────────

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('cccc0000-0000-0000-0000-000000000001',
             'bbbb0000-0000-0000-0000-000000000002', 11) $$,
  '23514'::text, null::text,
  'a score above 10 is refused'
);

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('cccc0000-0000-0000-0000-000000000001',
             'bbbb0000-0000-0000-0000-000000000002', -1) $$,
  '23514'::text, null::text,
  'and below 0'
);

-- The single most important row shape on this table: declining is an answer.
insert into public.ratings (claim_id, user_id, score)
values ('cccc0000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000002', null);

select is(
  (select count(*)::int from public.ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  1,
  'a NULL score is a real row: "no opinion" is recorded, not absent'
);

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('cccc0000-0000-0000-0000-000000000001',
             'bbbb0000-0000-0000-0000-000000000002', 7) $$,
  '23505'::text, null::text,
  'one rating per person per claim'
);

-- Changing your mind is an update, and it keeps only the current value.
update public.ratings set score = 7
 where claim_id = 'cccc0000-0000-0000-0000-000000000001'
   and user_id = 'bbbb0000-0000-0000-0000-000000000002';

select is(
  (select count(*)::int from public.ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  1,
  'editing a rating leaves one row, not a history'
);

-- ── Nobody reads anybody else's rating ──────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbb0000-0000-0000-0000-000000000002","role":"authenticated"}';

select is(
  (select score from public.ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  7::smallint,
  'a member reads their own rating'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbb0000-0000-0000-0000-000000000003","role":"authenticated"}';

select is(
  (select count(*)::int from public.ratings),
  0,
  'and cannot read anybody else''s, which is the rule the aggregate is built around'
);

select is_empty(
  $$ select user_id, score from public.ratings
      where user_id = 'bbbb0000-0000-0000-0000-000000000002' $$,
  'naming the person does not help'
);

reset role;

set local role anon;
select throws_ok(
  $$ select count(*) from public.ratings $$,
  '42501'::text, null::text,
  'anon has no access to ratings at all'
);
reset role;

-- ── Who may rate ────────────────────────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbb0000-0000-0000-0000-000000000004","role":"authenticated"}';

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('cccc0000-0000-0000-0000-000000000001',
             'bbbb0000-0000-0000-0000-000000000004', 5) $$,
  '42501'::text, null::text,
  'an unconfirmed account cannot rate'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbb0000-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('cccc0000-0000-0000-0000-000000000001',
             'bbbb0000-0000-0000-0000-000000000002', 5) $$,
  '42501'::text, null::text,
  'and nobody can rate on somebody else''s behalf'
);

select throws_ok(
  $$ insert into public.ratings (claim_id, user_id, score)
     values ('cccc0000-0000-0000-0000-000000000003',
             'bbbb0000-0000-0000-0000-000000000003', 5) $$,
  '42501'::text, null::text,
  'a hidden claim stops accepting ratings'
);

reset role;

-- ── Claims ─────────────────────────────────────────────────────────────────────────

set local role anon;

select is(
  (select count(*)::int from public.claims),
  2,
  'anon sees every claim that is not hidden'
);

reset role;

set local role authenticated;
set local request.jwt.claims to '{"sub":"bbbb0000-0000-0000-0000-000000000003","role":"authenticated"}';

select throws_ok(
  $$ insert into public.claims (author_id, statement, area, status)
     values ('bbbb0000-0000-0000-0000-000000000003',
             'This one arrives already hidden, which nobody may do.', 'other', 'hidden') $$,
  '42501'::text, null::text,
  'nobody can name status when posting a claim: it has no INSERT grant in either direction'
);

insert into public.claims (author_id, statement, area)
values ('bbbb0000-0000-0000-0000-000000000003',
        'Referee reports should say whether a tool was used.', 'research');

reset role;

select is(
  (select status::text from public.claims
    where statement = 'Referee reports should say whether a tool was used.'),
  'active'::text,
  'a confirmed member may post a claim, and it is part of the record at once'
);

select isnt(
  (select activated_at from public.claims
    where statement = 'Referee reports should say whether a tool was used.'),
  null::timestamptz,
  'with the date the CHECK ties to that status, from the column default'
);

select throws_ok(
  $$ insert into public.claims (author_id, statement, area)
     values ('bbbb0000-0000-0000-0000-000000000001', 'Maybe?', 'other') $$,
  '23514'::text, null::text,
  'a statement too short to be a claim is refused'
);

select throws_ok(
  $$ insert into public.claims (author_id, statement, area)
     values ('bbbb0000-0000-0000-0000-000000000001', repeat('x', 201), 'other') $$,
  '23514'::text, null::text,
  'and one longer than a sentence: two claims sharing a rating mean nothing'
);

-- ── Nothing promotes any more ───────────────────────────────────────────────────────
-- A claim used to become part of the record once enough people had rated it, which existed
-- to get claims out of a moderation queue without a moderator. There is no queue: a claim
-- is active when it is written. What has to be asserted now is the absence — a trigger left
-- behind would fire on rows a moderator had hidden and unhidden, and quietly re-promote
-- something that had just been put back deliberately.

select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.ratings'::regclass and not tgisinternal
      and tgname = 'ratings_promote_debate'),
  0,
  'no promotion trigger is left on public.ratings'
);

select is(
  (select count(*)::int from private.settings where key = 'debate_activation_ratings'),
  0,
  'and the threshold it read is gone from private.settings'
);

insert into public.ratings (claim_id, user_id, score) values
  ('cccc0000-0000-0000-0000-000000000002', 'bbbb0000-0000-0000-0000-000000000001', 9),
  ('cccc0000-0000-0000-0000-000000000002', 'bbbb0000-0000-0000-0000-000000000002', null),
  ('cccc0000-0000-0000-0000-000000000002', 'bbbb0000-0000-0000-0000-000000000003', 2);

select is(
  (select status::text from public.claims
    where id = 'cccc0000-0000-0000-0000-000000000002'),
  'proposed'::text,
  'and rating a claim no longer changes its status, however many people answer'
);

-- ── The aggregate ───────────────────────────────────────────────────────────────────
-- Six raters on the active claim: scores 7, 2, 8, 8, and two who declined.

insert into public.ratings (claim_id, user_id, score) values
  ('cccc0000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000003', 2),
  ('cccc0000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001', 8),
  ('cccc0000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000004', null);

set local role anon;

select is(
  (select histogram from public.claim_ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  array[0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0],
  'the histogram counts each of the eleven values, and anon may read it'
);

select is(
  (select median from public.claim_ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  7::smallint,
  'the median is a value somebody actually chose, not an interpolation between two'
);

select is(
  (select total_raters from public.claim_ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  4,
  'everyone who answered is counted, including those who declined'
);

select is(
  (select no_opinion_count from public.claim_ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  1,
  'declining is its own number rather than a gap'
);

select is(
  (select coverage from public.claim_ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  0.750::numeric,
  'and coverage is the ratio of opinions to raters'
);

select is_empty(
  $$ select claim_id from public.claim_ratings
      where claim_id = 'cccc0000-0000-0000-0000-000000000003' $$,
  'a hidden claim has no readable aggregate'
);

reset role;

-- ── The mean: one place computes it, and it is not a headline ───────────────────────
-- Until 2026-08-21 this section asserted that nothing anywhere computed an average. The
-- analysis behind that has not changed — the mean of an 11-point bipolar scale reports mild
-- agreement for a community that has split cleanly in two, which is the exact shape this
-- corpus exists to make visible — but the conclusion has: a mean shown beside the median and
-- never without the histogram is a statistic a reader can weigh, where a withheld one is a
-- statistic they compute themselves, less carefully, with no caveat beside it.
--
-- So the assertion is narrowed rather than deleted, and it is still written against the
-- catalogue rather than against a list of objects, so it still covers whatever is added next.
-- `public.rating_aggregate` is exempt **by name**. Anything else in the exposed schema that
-- grows an `avg(` still fails here, which is the property worth keeping: the danger was never
-- one mean, it was a second one computed somewhere else to a different definition.
--
-- What this cannot assert is the display rule — that the mean never appears as a card
-- headline, on a sort control, or without the histogram. That lives in CLAUDE.md, in the
-- comment on the function, and in review.

select is_empty(
  $$ select p.proname
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prokind = 'f'
        and p.proname <> 'rating_aggregate'
        and pg_get_functiondef(p.oid) ~* '\mavg\s*\(' $$,
  'no function in the exposed schema computes an average except public.rating_aggregate'
);

-- The view is unexempted and still passes: it calls the function rather than restating the
-- arithmetic, so its definition holds no `avg(` of its own. That is the point of the function
-- being under the view, and this assertion is what would notice somebody inlining it.
select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'v'
        and pg_get_viewdef(c.oid) ~* '\mavg\s*\(' $$,
  'and no view computes one at all: claim_ratings calls the function instead of restating it'
);

-- Three opinions on the active claim — 2, 7 and 8 — and one person who declined. The mean is
-- 17/3, and the assertion is really about the denominator: the person who chose "no opinion"
-- is not in it. Were they counted as anything at all, this would read 4.25.
set local role anon;

select is(
  (select mean from public.claim_ratings
    where claim_id = 'cccc0000-0000-0000-0000-000000000001'),
  5.67::numeric,
  'the mean is reported beside the median, over the opinions only'
);

reset role;

select * from finish();

rollback;
