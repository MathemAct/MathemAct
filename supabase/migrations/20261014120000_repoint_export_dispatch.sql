-- Point private.dispatch_export() at the repository the site is now deployed from.
--
-- 20261011120000 hardcoded the workflow-dispatch URL of EmmaZanoli/MathemAct. The code moved to
-- MathemAct/MathemAct (a fresh repository, no history), and without this the database would keep
-- asking the old repository to run export.yml, so content changes would reach the static pages
-- only at the nightly run. Only the URL changes; the body is otherwise the one from
-- 20261011120000, and no other migration has touched this function.
--
-- Same signature, so create or replace swaps the definition rather than adding a second function.
-- The Vault secret github_export_dispatch is not touched here: it must be replaced by hand with a
-- token scoped to the new repository (docs/auth.md §6), and never goes in a migration.

create or replace function private.dispatch_export()
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
  -- read here is everything committed so far.
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
           url := 'https://api.github.com/repos/MathemAct/MathemAct/actions/workflows/export.yml/dispatches',
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

-- create or replace keeps the existing privileges, but a reissued function is the place to say so.
revoke all on function private.dispatch_export() from public;
