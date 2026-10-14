-- Reconstructing the activity feed from history, and doing it exactly once.
--
-- The backfill exists because triggers observe statements and nothing was watching before
-- 20260818120100. Everything that matters about it is in two properties:
--
--   **It uses the real dates.** A feed stamped with the date of the migration would be a
--   lie in the one column people read as history. Every source table carries created_at and
--   public.moderation_actions is a complete dated log, so the reconstruction is exact.
--
--   **It cannot write a row twice.** It has to be safe over rows the triggers already saw,
--   because the migration lands after the triggers have been live for a while, and safe to
--   run again by hand. The guard is the timestamp: a trigger fires in the same transaction
--   as the row that fired it, so the activity row's now() and the source row's created_at
--   are the same value, not merely close. That is what separates the pairs that would
--   otherwise collide — two people rating one claim, several comments on one report.
--
-- The setup below turns the triggers off, writes history underneath them, and turns them
-- back on. That is what the production database looked like on the morning this ran.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(12);

-- ── People ──────────────────────────────────────────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'author@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'reader@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('11111111-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'moderator@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();
update public.profiles set role = 'moderator' where id = '11111111-0000-0000-0000-000000000003';

-- ── History, written with nothing watching ──────────────────────────────────────────

alter table public.reports            disable trigger reports_activity_insert;
alter table public.comments           disable trigger comments_activity_insert;
alter table public.moderation_actions disable trigger moderation_actions_activity_insert;

insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed, created_at
) values
  ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'published', 'Checking a lemma in Lean', 'research', 'proof_checking',
   'Confirm a lemma.', 'Stated it in Lean.', 'worked', 'It closed.', 'Lean accepted it.',
   true, '2026-07-01T10:00:00Z');

insert into public.comments (id, parent_type, parent_id, author_id, body, created_at)
values
  ('44444444-0000-0000-0000-000000000001', 'report', '22222222-0000-0000-0000-000000000001',
   '11111111-0000-0000-0000-000000000002', 'Did the elaborator accept it without hints?',
   '2026-07-02T09:30:00Z');

-- A `publish` row: the action no longer exists in the interface, and rows carrying it are
-- exactly what this backfill has to keep reconstructing. It needs a reason here only
-- because moderation_actions_reason_required now asks for one on every new row — the real
-- historical rows predate that constraint, which is why it was added NOT VALID.
insert into public.moderation_actions
  (actor_id, action, target_type, target_id, reason, created_at)
values
  ('11111111-0000-0000-0000-000000000003', 'publish', 'report',
   '22222222-0000-0000-0000-000000000001', 'Reads well; verification is real.',
   '2026-07-01T16:00:00Z');

-- The triggers are deliberately never switched back on. `ALTER TABLE ... ENABLE TRIGGER`
-- refuses while the table has a pending trigger event, and inserting a report always leaves
-- one: reports_require_a_tool is a *deferred* constraint trigger, so it sits queued until
-- commit. Flushing it would mean SET CONSTRAINTS ALL IMMEDIATE, which this repo has already
-- been bitten by once — it survives ROLLBACK TO SAVEPOINT and changes the mode for the rest
-- of the file.
--
-- Nothing needs them back. The disable is transactional and the rollback at the bottom undoes
-- it, and the one assertion that needs a live trigger uses a claim, whose trigger was never
-- touched.

select is(
  (select count(*)::int from public.activity),
  0,
  'nothing was recorded while the triggers were off, which is how the feed came to be empty'
);

-- ── The reconstruction ──────────────────────────────────────────────────────────────

select cmp_ok(
  private.backfill_activity(),
  '>',
  0,
  'the backfill writes rows'
);

select is(
  (select count(*)::int from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'posted_report'),
  1,
  'a report posted before the feature exists is in its author''s feed afterwards'
);

select is(
  (select created_at from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'posted_report'),
  '2026-07-01T10:00:00Z'::timestamptz,
  'dated when it happened, not when the backfill ran'
);

select is(
  (select actor_id from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'content_commented'),
  '11111111-0000-0000-0000-000000000002'::uuid,
  'somebody else''s comment is reconstructed with their name on it'
);

select is(
  (select count(*)::int from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'report_published'),
  1,
  'and the decision to publish it, which only the audit log remembered'
);

select is(
  (select actor_id from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'report_published'),
  null::uuid,
  'still without naming the moderator: the backfill goes through the same routing'
);

-- ── Twice ───────────────────────────────────────────────────────────────────────────

select is(
  private.backfill_activity(),
  0,
  'running it again writes nothing'
);

select is(
  (select count(*)::int from public.activity
    where subject_id = '11111111-0000-0000-0000-000000000001'
      and kind = 'posted_report'),
  1,
  'and leaves one row where there was one row'
);

-- ── Over something the triggers already saw ─────────────────────────────────────────
-- The case this has to survive in production: the migration lands after the triggers have
-- been live, so most of what the backfill walks is already there.
--
-- A claim rather than a report, because claims_activity_insert was never disabled above.
-- It writes its own feed row on insert, exactly as it would in production, and the backfill
-- then walks straight over it.

-- Named without a status, so it takes the default the site now writes. Naming `proposed`
-- here used to be harmless and is not: `activated_at` defaults to now() since
-- 20260818180000, and claims_activated_iff_active refuses the pair.
insert into public.claims (id, author_id, statement, area)
values
  ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
   'Posted while the triggers were live.', 'writing');

select is(
  (select count(*)::int from public.activity
    where target_id = '33333333-0000-0000-0000-000000000001'
      and kind = 'posted_claim'),
  1,
  'the live trigger wrote its row, as it does in production'
);

select is(
  private.backfill_activity(),
  0,
  'and the backfill walks over it without reconstructing it on top of itself'
);

select is(
  (select count(*)::int from public.activity
    where target_id = '33333333-0000-0000-0000-000000000001'
      and kind = 'posted_claim'),
  1,
  'leaving one row where there was one row'
);

select * from finish();

rollback;
