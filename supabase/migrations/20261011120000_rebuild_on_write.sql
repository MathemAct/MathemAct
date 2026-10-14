-- The site rebuilds when its content changes, rather than once a night.
--
-- Reads are served from the static export (CLAUDE.md, *Read/write split*), and until now that
-- export ran on a schedule only. GitHub starts scheduled jobs hours late — the 03:17 run has been
-- starting around 10:00 UTC — so anything posted, edited, endorsed, renamed or hidden waited up to
-- a day to reach the pages everybody else reads. To somebody who has just done it, that looks like
-- the site not working. The export itself takes about twenty seconds and the deploy under a
-- minute; the only slow part was waiting to be asked.
--
-- How it works
-- ------------
-- 1. Every statement that writes to a table scripts/export.mjs reads bumps a counter in
--    private.export_queue, through a statement-level trigger.
-- 2. pg_cron runs private.dispatch_export() once a minute. If the counter has moved since the last
--    dispatch, it asks GitHub to run .github/workflows/export.yml, through pg_net. The export
--    commits whatever changed and asks for a deploy, as it always has.
--
-- So a write reaches every static page in about two minutes, and the database asks at most once a
-- minute however busy the site is. export.yml's concurrency group keeps at most one run waiting,
-- so a burst of writes never queues a burst of runs.
--
-- Why a counter and not a timestamp
-- ---------------------------------
-- now() is when a transaction *started*, not when it committed. A write that began just before a
-- dispatch and committed just after it would carry a time earlier than the dispatch and never be
-- asked for. A counter compared against the value at the last dispatch has no such gap: an
-- increment either committed before dispatch_export() locked the row, and is in the export that
-- run starts, or happens after, and moves the counter past the dispatched value.
--
-- Why Postgres makes the call
-- ---------------------------
-- Hard constraint 5 is to keep logic in Postgres and avoid an Edge Function unless something needs
-- an outbound call at request time. This needs one, and pg_net makes it from inside the database,
-- so there is still no Edge Function. Both extensions are on the free plan.
--
-- The token
-- ---------
-- A fine-grained GitHub token that can do one thing: start workflows on this repository. It lives
-- in Supabase Vault under the name `github_export_dispatch`, put there by hand (docs/auth.md),
-- never in a migration and never in the repository. **Without it this file changes nothing**:
-- dispatch_export() finds no token and returns, which is also what it does in CI. The nightly
-- schedule in export.yml stays, as the fallback and as the connection that stops a free project
-- pausing.
--
-- Exposure
-- --------
-- Everything here is in `private`, revoked from PUBLIC, and reachable by no browser role, so it
-- adds no Security Advisor warning and no write path — the count of ban clauses stays nine.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ── The queue ───────────────────────────────────────────────────────────────────────
-- One row. Every content write updates it, so it is a hot row, and that is acceptable here: a
-- write takes its lock for the length of one short PostgREST transaction.

create table private.export_queue (
  id                    boolean primary key default true check (id),
  generation            bigint      not null default 0,
  dispatched_generation bigint      not null default 0,
  changed_at            timestamptz,
  dispatched_at         timestamptz,
  last_request_id       bigint,
  -- The HTTP status GitHub answered the last dispatch with; 0 when there was no response at all.
  -- Read by scripts/export.mjs, which warns when it is not 2xx — an expired token would otherwise
  -- show up only as a site that quietly went back to updating once a day.
  last_status           integer,
  last_status_at        timestamptz
);

alter table private.export_queue enable row level security;

insert into private.export_queue default values;

comment on table private.export_queue is
  'One row. generation moves on every write to an exported table; dispatch_export() asks GitHub '
  'for an export when it has moved past dispatched_generation.';

-- ── Noting a change ─────────────────────────────────────────────────────────────────
-- SECURITY DEFINER because the writer is a browser role and holds nothing on `private`. It asks
-- nothing about who is writing, so it is not the guard trap. Statement-level, so a bulk statement
-- costs one update rather than one per row. A statement that changes no rows still fires it; the
-- cost of that is one export that finds nothing to commit.

create function private.note_content_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- `where id` names the one row; an UPDATE without a WHERE is refused where safeupdate is loaded.
  update private.export_queue
     set generation = generation + 1,
         changed_at = now()
   where id;
  return null;
end;
$$;

comment on function private.note_content_changed() is
  'Statement-level trigger on every table the export reads: moves private.export_queue.generation.';

revoke all on function private.note_content_changed() from public;

-- Every table scripts/export.mjs reads, under its current name (20260817130000 renamed most of
-- them). Views are not here: debate_ratings and report_staleness read these tables, and
-- rating_changes is written only by a trigger on ratings. Moderation and erasure write to these
-- same tables, so a hide, an unhide and an erasure are all noticed. A table added to the export
-- needs a trigger here as well, or its changes wait for the night.
do $$
declare
  t text;
begin
  foreach t in array array[
    'reports', 'report_tools', 'report_tags', 'report_confirmations', 'citations',
    'debates', 'debate_tags', 'ratings',
    'comments', 'comment_endorsements',
    'network_entries', 'profiles', 'tags'
  ]
  loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I '
      'for each statement execute function private.note_content_changed()',
      t || '_note_content_changed', t);
  end loop;
end;
$$;

-- ── Asking GitHub ───────────────────────────────────────────────────────────────────
-- SECURITY DEFINER so it can read Vault and call pg_net, which only the owner may. Run by pg_cron
-- as the role that scheduled it, never by a browser.

create function private.dispatch_export()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_queue  private.export_queue%rowtype;
  v_token  text;
  v_status integer;
begin
  -- FOR UPDATE waits for any write that has bumped the counter and not yet committed, so what is
  -- read here is everything committed so far. See the header on why that closes the gap.
  select * into v_queue from private.export_queue where id for update;

  -- How the previous request went. pg_net keeps responses for hours, not days, so this is read on
  -- the next tick rather than at the next dispatch, which may be a week away.
  if v_queue.last_request_id is not null and v_queue.last_status is null then
    select coalesce(r.status_code, 0)
      into v_status
      from net._http_response r
     where r.id = v_queue.last_request_id;

    if found then
      update private.export_queue
         set last_status = v_status,
             last_status_at = now()
       where id;
    end if;
  end if;

  if v_queue.generation <= v_queue.dispatched_generation then
    return;
  end if;

  select s.decrypted_secret
    into v_token
    from vault.decrypted_secrets s
   where s.name = 'github_export_dispatch';

  -- Not configured. Leave dispatched_generation where it is, so the first tick after the token is
  -- stored asks for everything that changed in the meantime.
  if v_token is null or v_token = '' then
    return;
  end if;

  update private.export_queue
     set dispatched_generation = v_queue.generation,
         dispatched_at = now(),
         last_status = null,
         last_status_at = null,
         last_request_id = net.http_post(
           url := 'https://api.github.com/repos/EmmaZanoli/MathemAct/actions/workflows/export.yml/dispatches',
           body := jsonb_build_object('ref', 'main'),
           headers := jsonb_build_object(
             'Authorization', 'Bearer ' || v_token,
             'Accept', 'application/vnd.github+json',
             'X-GitHub-Api-Version', '2022-11-28',
             -- GitHub refuses a request without one.
             'User-Agent', 'MathemAct-export-dispatch',
             'Content-Type', 'application/json'
           ),
           timeout_milliseconds := 10000
         )
   where id;
end;
$$;

comment on function private.dispatch_export() is
  'Run by pg_cron each minute. Asks GitHub to run export.yml when an exported table has changed '
  'since the last dispatch. Does nothing until the Vault secret github_export_dispatch exists.';

revoke all on function private.dispatch_export() from public;

-- cron.schedule with a name replaces a job of the same name, so this is safe to run again.
select cron.schedule('dispatch-export', '* * * * *', 'select private.dispatch_export()');
