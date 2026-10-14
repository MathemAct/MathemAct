-- Rebuilding on write: a counter every content write moves, and a dispatcher that asks GitHub for
-- an export when it has moved.
--
-- **Nothing here reaches GitHub.** net.http_post() only inserts into net.http_request_queue, and
-- pg_net's worker reads committed rows. This file ends in ROLLBACK, so the request asserted below,
-- and the Vault secret it is built from, never exist outside this transaction.
--
-- The writes are statements that touch no rows. A statement-level trigger fires on those too, and
-- that is what makes them useful here: they prove the trigger is attached, and runs for a browser
-- role, without fixtures that every future column change could break.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(17);

-- ── The queue ───────────────────────────────────────────────────────────────────────

select is(
  (select count(*)::int from private.export_queue),
  1,
  'the queue is one row'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.export_queue'::regclass),
  'row level security is enabled on private.export_queue'
);

select ok(
  not has_table_privilege('anon', 'private.export_queue', 'SELECT')
  and not has_table_privilege('authenticated', 'private.export_queue', 'SELECT'),
  'no browser role can read the queue'
);

-- ── The triggers ────────────────────────────────────────────────────────────────────
-- tgtype 28 is INSERT (4) + DELETE (8) + UPDATE (16): AFTER, because BEFORE is bit 2, and FOR
-- EACH STATEMENT, because ROW is bit 1.

select is(
  (select count(*)::int
     from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and t.tgname = c.relname || '_note_content_changed'
      and t.tgfoid = 'private.note_content_changed'::regproc
      and t.tgtype = 28
      and c.relname in (
        'reports', 'report_tools', 'report_tags', 'report_confirmations', 'citations',
        'claims', 'claim_tags', 'ratings',
        'comments', 'comment_endorsements',
        'network_entries', 'profiles', 'tags'
      )),
  13,
  'every table the export reads notes a change, after each insert, update or delete statement'
);

-- ── A write moves the counter ───────────────────────────────────────────────────────

create temporary table seen (generation bigint) on commit drop;
insert into seen select generation from private.export_queue;

update public.comments set body = body where false;

select ok(
  (select generation from private.export_queue) > (select generation from seen),
  'a statement on comments moves the counter'
);

select ok(
  (select changed_at from private.export_queue) is not null,
  'and stamps when'
);

update seen set generation = (select generation from private.export_queue);

-- As a browser role. The trigger function is DEFINER because `authenticated` holds nothing on
-- `private`; this is the assertion that it does not need to.
set local role authenticated;
delete from public.comment_endorsements where false;
reset role;

select ok(
  (select generation from private.export_queue) > (select generation from seen),
  'a statement by a browser role moves the counter too'
);

-- ── Dispatching, with no token ──────────────────────────────────────────────────────

select is(
  (select count(*)::int from vault.decrypted_secrets where name = 'github_export_dispatch'),
  0,
  'precondition: no dispatch token is stored'
);

update seen set generation = (select count(*) from net.http_request_queue);

select private.dispatch_export();

select is(
  (select count(*) from net.http_request_queue),
  (select generation from seen),
  'without a token, nothing is asked for'
);

select ok(
  (select dispatched_generation < generation from private.export_queue),
  'and the change stays owed, so the first tick after the token is stored asks for it'
);

-- ── Dispatching, with a token ───────────────────────────────────────────────────────

select vault.create_secret('test-token-never-sent', 'github_export_dispatch');

select private.dispatch_export();

select is(
  (select count(*) from net.http_request_queue),
  (select generation from seen) + 1,
  'with a token and a change owed, one request is queued'
);

select results_eq(
  $$ select q.method::text, q.url, q.headers->>'Authorization'
       from net.http_request_queue q
      where q.id = (select last_request_id from private.export_queue) $$,
  $$ values ('POST',
             'https://api.github.com/repos/MathemAct/MathemAct/actions/workflows/export.yml/dispatches',
             'Bearer test-token-never-sent') $$,
  'to the export workflow''s dispatch endpoint, carrying the token'
);

select ok(
  (select dispatched_generation = generation and dispatched_at is not null
     from private.export_queue),
  'and the change is marked as asked for'
);

select private.dispatch_export();

select is(
  (select count(*) from net.http_request_queue),
  (select generation from seen) + 1,
  'a second tick with nothing new asks for nothing'
);

-- ── Exposure ────────────────────────────────────────────────────────────────────────

select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'private'
       and p.proname in ('note_content_changed', 'dispatch_export')
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
            or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ),
  'neither function is reachable from a browser'
);

select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname in ('note_content_changed', 'dispatch_export')
      and p.prosecdef
      and 'search_path=""' = any (p.proconfig)),
  2,
  'both are DEFINER with the search path pinned'
);

select results_eq(
  $$ select schedule, command from cron.job where jobname = 'dispatch-export' $$,
  $$ values ('* * * * *'::text, 'select private.dispatch_export()'::text) $$,
  'the dispatcher runs every minute'
);

select * from finish();

rollback;
