-- Fix two bugs introduced when 20260816100000_resources.sql replaced shared functions.
--
-- Bug 1: enforce_daily_limit() lost its citations and reports branches.
-- 20260816100000 added the resources branch via CREATE OR REPLACE, but the function body
-- it replaced belonged to 20260815180300_discussion_rate_limits.sql, which had added
-- citations and reports. The replacement silently dropped both. Any INSERT into citations
-- or reports now fires the trigger's else branch and raises the "has no rule for table"
-- exception, blocking citations and reports entirely.
--
-- Bug 2: protect_resource_columns() calls private.normalise_url() as SECURITY INVOKER.
-- The authenticated role has no access to the private schema, so any UPDATE made by a
-- browser user (editing a pending resource, moderator hiding one, etc.) fails immediately
-- with "permission denied for schema private". The INSERT normalise trigger
-- (normalise_resource_url) has the same call but only fires on INSERT, which always comes
-- from trusted callers and therefore works.
--
-- Fix for bug 2 (two changes, one commit):
--   a) normalise_resource_url() becomes SECURITY DEFINER so it can always reach
--      private.normalise_url, and fires on INSERT OR UPDATE instead of INSERT only.
--      Trigger alphabetical order puts it before protect_resource_columns, so
--      url_normalised is always computed before the guard runs.
--   b) protect_resource_columns() drops its private.normalise_url call.
--      The guard still reverts url_normalised to the old value when the resource is past
--      pending or when a non-moderator tries to change status — the normalised value is
--      already in new.url_normalised when the guard fires (from step a), so the revert
--      logic works exactly as before.

-- ── Bug 1: restore citations and reports branches in enforce_daily_limit() ────────────────

create or replace function private.enforce_daily_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author  uuid;
  v_limit   integer;
  v_count   integer;
  v_key     text;
  v_noun    text;
begin
  case tg_table_name
    when 'practices' then
      v_key    := 'rate_limit_practices_per_day';
      v_noun   := 'practices';
      v_author := new.author_id;

      select count(*) into v_count
        from public.practices p
       where p.author_id = v_author
         and p.created_at > now() - interval '24 hours';

    when 'practice_confirmations' then
      v_key    := 'rate_limit_confirmations_per_day';
      v_noun   := 'confirmations';
      v_author := new.user_id;

      select count(*) into v_count
        from public.practice_confirmations c
       where c.user_id = v_author
         and c.created_at > now() - interval '24 hours';

    when 'comments' then
      v_key    := 'rate_limit_comments_per_day';
      v_noun   := 'comments';
      v_author := new.author_id;

      select count(*) into v_count
        from public.comments c
       where c.author_id = v_author
         and c.created_at > now() - interval '24 hours';

    when 'citations' then
      v_key    := 'rate_limit_citations_per_day';
      v_noun   := 'citations';
      v_author := new.created_by;

      select count(*) into v_count
        from public.citations c
       where c.created_by = v_author
         and c.created_at > now() - interval '24 hours';

    when 'reports' then
      v_key    := 'rate_limit_reports_per_day';
      v_noun   := 'reports';
      v_author := new.reporter_id;

      select count(*) into v_count
        from public.reports r
       where r.reporter_id = v_author
         and r.created_at > now() - interval '24 hours';

    when 'resources' then
      v_key    := 'rate_limit_resources_per_day';
      v_noun   := 'resources';
      v_author := new.submitter_id;

      select count(*) into v_count
        from public.resources r
       where r.submitter_id = v_author
         and r.created_at > now() - interval '24 hours';

    else
      raise exception 'private.enforce_daily_limit() has no rule for table %', tg_table_name
        using errcode = '0A000';
  end case;

  if v_author is null then
    return new;
  end if;

  select s.value::integer into v_limit
    from private.settings s
   where s.key = v_key;

  if v_limit is null then
    raise exception 'Rate limit % is not configured.', v_key
      using errcode = '53400';
  end if;

  if v_count >= v_limit then
    raise exception
      'Daily limit reached: % % in the last 24 hours, which is the maximum. Try again later.',
      v_count, v_noun
      using errcode = '53400',
            hint = 'This limit exists so one account cannot bury a volunteer moderation queue.';
  end if;

  return new;
end;
$$;

comment on function private.enforce_daily_limit() is
  'Refuses an insert that would exceed the per-author rolling 24 hour limit in '
  'private.settings. SECURITY DEFINER so the count includes rows the caller cannot see and '
  'so the threshold itself stays unreadable from a browser. Covers practices, confirmations, '
  'comments, citations, reports, and resources.';

revoke all on function private.enforce_daily_limit() from public;

-- ── Bug 2a: make normalise_resource_url() DEFINER and extend it to UPDATE ─────────────────

-- The INSERT-only trigger must be dropped and recreated to add UPDATE. DROP removes the
-- trigger definition; the function itself is replaced below, keeping existing privileges.
drop trigger resources_a_normalise_url on public.resources;

create or replace function private.normalise_resource_url()
returns trigger
language plpgsql
security definer        -- must reach private.normalise_url; INSERT also needs this
set search_path = ''
as $$
begin
  new.url_normalised := private.normalise_url(new.url);
  return new;
end;
$$;

comment on function private.normalise_resource_url() is
  'Sets url_normalised from url before every insert or update. SECURITY DEFINER: '
  'private.normalise_url is in the private schema and the authenticated role cannot '
  'call it directly. Alphabetical trigger order puts this before protect_resource_columns, '
  'so the guard always sees an already-normalised value.';

revoke all on function private.normalise_resource_url() from public;

create trigger resources_a_normalise_url
  before insert or update on public.resources
  for each row
  execute function private.normalise_resource_url();

-- ── Bug 2b: remove the private.normalise_url call from protect_resource_columns() ─────────

create or replace function private.protect_resource_columns()
returns trigger
language plpgsql
security invoker        -- must remain INVOKER: current_user check decides who is trusted
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  -- url_normalised was already set by normalise_resource_url() which fires before this
  -- trigger (alphabetical: resources_a_ before resources_b_). The old direct call to
  -- private.normalise_url() is removed because the authenticated role cannot reach the
  -- private schema, causing every browser UPDATE to fail with permission denied.
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.resources'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for everyone.
  new.id           := old.id;
  new.submitter_id := old.submitter_id;
  new.created_at   := old.created_at;

  -- Status, link check, and moderation columns are for moderators and the link-check
  -- script respectively. No browser caller may write them.
  new.status             := old.status;
  new.link_status        := old.link_status;
  new.link_checked_at    := old.link_checked_at;
  new.moderation_note    := old.moderation_note;
  new.moderation_note_at := old.moderation_note_at;
  new.moderation_note_by := old.moderation_note_by;

  -- Restoring a deleted resource is a moderation action.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- Once past pending, the content is fixed.
  if old.status <> 'pending' then
    new.title          := old.title;
    new.url            := old.url;
    new.url_normalised := old.url_normalised;
    new.category       := old.category;
    new.description    := old.description;
    new.relevance      := old.relevance;
  end if;

  return new;
end;
$$;

comment on function private.protect_resource_columns() is
  'Reverts writes to columns the caller does not own. Deliberately SECURITY INVOKER: '
  'as DEFINER, current_user would always be the owner and the guard would never fire. '
  'URL normalisation is handled by the preceding normalise_resource_url() trigger.';

revoke all on function private.protect_resource_columns() from public;
