-- The staleness view, and the trap underneath it.
--
-- A view has no row level security of its own. Without `security_invoker = on` it runs
-- with its creator's privileges and returns every report it can see -- pending, hidden,
-- deleted -- to anonymous callers, while the policies on the underlying tables sit there
-- being perfectly correct and never being consulted. The first assertion in this file is
-- the one that would catch that, and it is why the file exists at all.
--
-- The rest is the tombstone rule. It lives in SQL because the same answer has to appear in
-- a listing, on a report page, in the nightly JSON export, and in whatever a researcher
-- runs against the dumped corpus; four implementations would be four definitions of
-- "verified".

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(19);

insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('55555555-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'poster@example.org', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('55555555-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'checker@example.org', '{}'::jsonb, '{}'::jsonb, now(), now());

update auth.users set email_confirmed_at = now();

-- Seven published reports and one hidden one that no anonymous caller may learn anything
-- about. Reports 1 to 5 cover every tombstone state reachable from a success, plus a
-- second route to 'stale'; 7 and 8 are the failure side.
insert into public.reports (
  id, author_id, status, title, area, task_type, aim, method, outcome, outcome_notes,
  verification, third_party_material_confirmed
)
select
  ('66666666-0000-0000-0000-00000000000' || n)::uuid,
  '55555555-0000-0000-0000-000000000001',
  case when n = 6 then 'hidden' else 'published' end::public.content_status,
  'Report ' || n, 'research', 'other', 'a', 'b',
  -- 7 and 8 did not work, which is the whole point of them: the question their
  -- confirmations answer is "does this still not work?", and the two answers to it are
  -- the two values the view has to read alongside the original pair.
  case when n >= 7 then 'failed' else 'worked' end::public.report_outcome, 'c',
  'Checked it.', true
from generate_series(1, 8) as g(n);

insert into public.report_tools (report_id, tool_name, tool_version, used_on) values
  -- Recent, never confirmed.
  ('66666666-0000-0000-0000-000000000001', 'GPT-5', '2026-05', current_date - 20),
  -- Recent, confirmed working.
  ('66666666-0000-0000-0000-000000000002', 'GPT-5', '2026-05', current_date - 20),
  -- Recent, reported no longer working.
  ('66666666-0000-0000-0000-000000000003', 'GPT-5', '2026-05', current_date - 20),
  -- Old and never confirmed. Two tools, to check the view takes the newer of them.
  ('66666666-0000-0000-0000-000000000004', 'GPT-4', '2024-11', current_date - 900),
  ('66666666-0000-0000-0000-000000000004', 'Lean', '4.2.0', current_date - 800),
  -- Recent tool, but the last confirmation is two years old.
  ('66666666-0000-0000-0000-000000000005', 'GPT-5', '2026-05', current_date - 20),
  ('66666666-0000-0000-0000-000000000006', 'GPT-5', '2026-05', current_date - 20),
  -- The failure side. Recent, so the tool age never reaches the 'stale' branch and the
  -- verdict is the only thing deciding either of these.
  ('66666666-0000-0000-0000-000000000007', 'GPT-5', '2026-05', current_date - 20),
  ('66666666-0000-0000-0000-000000000008', 'GPT-5', '2026-05', current_date - 20);

insert into public.report_confirmations (report_id, user_id, verdict, created_at) values
  ('66666666-0000-0000-0000-000000000002', '55555555-0000-0000-0000-000000000002',
   'still_works', now() - interval '2 days'),
  ('66666666-0000-0000-0000-000000000003', '55555555-0000-0000-0000-000000000002',
   'no_longer_works', now() - interval '1 day'),
  ('66666666-0000-0000-0000-000000000005', '55555555-0000-0000-0000-000000000002',
   'still_works', now() - interval '2 years'),
  -- Rechecked, and it still does not work. This is a result, and the square is filled.
  ('66666666-0000-0000-0000-000000000007', '55555555-0000-0000-0000-000000000002',
   'still_fails', now() - interval '2 days'),
  -- Rechecked, and somebody got it working. The account no longer describes what happens.
  ('66666666-0000-0000-0000-000000000008', '55555555-0000-0000-0000-000000000002',
   'now_works', now() - interval '2 days');

-- An older verdict on the same report, to prove the view takes the most recent rather
-- than an arbitrary one.
insert into public.report_confirmations (report_id, user_id, verdict, created_at) values
  ('66666666-0000-0000-0000-000000000003', '55555555-0000-0000-0000-000000000001',
   'still_works', now() - interval '30 days');

-- ── The trap ────────────────────────────────────────────────────────────────────────

-- Cast, not string-compare: a boolean reloption reads back exactly as written, so the
-- migration's `security_invoker = on` is the string 'on' rather than 'true'.
select ok(
  coalesce(
    (select o.option_value
       from pg_options_to_table(
              (select c.reloptions from pg_class c
                where c.oid = 'public.report_staleness'::regclass)) o
      where o.option_name = 'security_invoker')::boolean,
    false),
  'the staleness view is security_invoker'
);

set local role anon;

select is_empty(
  $$ select report_id from public.report_staleness
      where report_id = '66666666-0000-0000-0000-000000000006' $$,
  'an anonymous client sees no hidden report through the staleness view'
);

select is(
  (select count(*)::int from public.report_staleness),
  7,
  'and sees exactly the seven published ones'
);

-- ── The tombstone rule ──────────────────────────────────────────────────────────────

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000001'),
  'unverified'::text,
  'recent, and nobody has confirmed it either way: unverified'
);

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000002'),
  'verified'::text,
  'recently confirmed still working: verified, and the square is filled'
);

select is(
  (select is_verified from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000002'),
  true,
  'is_verified agrees with the status, so nothing has to re-derive it'
);

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000003'),
  'changed'::text,
  'a report that it no longer works outranks an older report that it did'
);

select is(
  (select is_verified from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000003'),
  false,
  'and leaves the square open'
);

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000004'),
  'stale'::text,
  'never confirmed and written against a tool used over a year ago: stale'
);

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000005'),
  'stale'::text,
  'confirmed working, but two years ago: also stale, and honestly so'
);

-- ── The failure side ────────────────────────────────────────────────────────────────
-- These four are the reason 20260823100100 exists. Before it, a report whose outcome was
-- 'failed' could only be confirmed with 'still_works' or 'no_longer_works' -- answers to a
-- question it does not ask -- and the view read only those two names. Every assertion here
-- passes vacuously against the old view *and* the old enum, because neither could produce
-- the rows: the fixtures above are the test.

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000007'),
  'verified'::text,
  'a failure somebody rechecked and found still failing is verified, not unverified'
);

select is(
  (select is_verified from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000007'),
  true,
  'and fills the square on exactly the same terms as a reproduced success'
);

select is(
  (select tombstone_status from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000008'),
  'changed'::text,
  'a failure somebody has since got working has changed, which is the same status as a success that stopped'
);

select is(
  (select is_verified from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000008'),
  false,
  'and leaves the square open, because the account no longer describes what happens'
);

-- ── The inputs the view reports ─────────────────────────────────────────────────────

select is(
  (select latest_tool_use from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000004'),
  (current_date - 800),
  'latest_tool_use is the most recent across every tool on the report'
);

select is(
  (select confirmation_count from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000003'),
  2::bigint,
  'confirmation_count counts everyone who checked, not only the latest'
);

-- Zero rather than null. The lateral returns no row for a report nobody has confirmed,
-- and an uncoalesced left join would put a null here and a null in is_verified -- which
-- renders as an open square in the interface and as unclassifiable in the export.
select is(
  (select confirmation_count from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000001'),
  0::bigint,
  'a report nobody has confirmed reports zero confirmations, not null'
);

select is(
  (select is_verified from public.report_staleness
    where report_id = '66666666-0000-0000-0000-000000000001'),
  false,
  'and is unambiguously not verified, rather than unknown'
);

reset role;

-- ── An author sees their own hidden work ────────────────────────────────────────────
-- The same invoker rule that hides a hidden report from anon shows it to its author,
-- because it is the reports policies doing the work rather than anything in the view.

set local role authenticated;
set local request.jwt.claims to '{"sub":"55555555-0000-0000-0000-000000000001","role":"authenticated"}';

select is(
  (select count(*)::int from public.report_staleness),
  8,
  'the author sees their own hidden report in the view, and nobody else does'
);

reset role;

select * from finish();

rollback;
