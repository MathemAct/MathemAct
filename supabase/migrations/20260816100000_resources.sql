-- public.resources — community-curated links to tools, datasets, courses, and guidelines.
--
-- Resources are a lighter-weight contribution than practices: one minute to submit, one
-- click to find. The design mirrors practices in everything that matters — status pipeline,
-- RLS, rate limits, moderation, soft delete, CC BY, export — and cuts everything that does
-- not apply: no verification field, no transcript, no outcome, no staleness. A link either
-- works or it does not, and the monthly link-check workflow decides which.
--
-- URL deduplication
-- -----------------
-- `url_normalised` is computed by a BEFORE INSERT trigger from the raw URL. It lower-cases
-- the URL, strips the scheme and trailing slashes, and removes a fixed list of tracking
-- parameters (utm_*, fbclid, gclid, etc.) from the query string. A partial unique index
-- over non-deleted rows prevents the same link appearing twice. A deleted resource's URL
-- can be resubmitted; the index is partial so a new row is accepted.
--
-- Rate limit
-- ----------
-- 5 resources per 24 hours, tighter than practices (10). A link costs the submitter
-- nothing — a URL and two sentences — and is the most likely spam vector on this site.
--
-- Moderation
-- ----------
-- All state changes go through public.moderate(), same as practices. This migration adds
-- 'resource' to public.moderation_target and replaces public.moderate() with a version that
-- includes the resource branch. The replacement keeps all existing branches word-for-word;
-- reading it beside the original is the review.

-- ── URL normalisation ────────────────────────────────────────────────────────────────────

create function private.normalise_url(p_url text)
returns text
language sql
immutable strict
set search_path = ''
as $$
  with
  -- Lowercase and strip scheme.
  base as (
    select regexp_replace(lower(p_url), '^https?://', '') as u
  ),
  -- Split at '?' to separate path from query string.
  parts as (
    select
      split_part(u, '?', 1) as path_part,
      case when position('?' in u) > 0
           then substring(u from position('?' in u) + 1)
           else ''
      end as qs
    from base
  ),
  -- Strip trailing slashes from the path.
  clean_path as (
    select regexp_replace(path_part, '/+$', '') as path_part, qs
    from parts
  ),
  -- Remove tracking parameters from the query string.
  filtered_qs as (
    select
      path_part,
      (
        select string_agg(param, '&' order by param)
          from unnest(string_to_array(qs, '&')) as param
         where param <> ''
           and split_part(param, '=', 1) not in (
               'fbclid', 'gclid', 'mc_cid', 'mc_eid', 'msclkid', 'origin', 'ref',
               'source', 'utm_campaign', 'utm_content', 'utm_creative_format',
               'utm_id', 'utm_marketing_tactic', 'utm_medium', 'utm_source',
               'utm_source_platform', 'utm_term'
           )
      ) as clean_qs
    from clean_path
  )
  select case
           when clean_qs is not null and clean_qs <> ''
           then path_part || '?' || clean_qs
           else path_part
         end
    from filtered_qs
$$;

comment on function private.normalise_url(text) is
  'Canonical form of a URL for deduplication: lowercased, scheme stripped, trailing '
  'slash stripped, tracking parameters removed. Kept in sync with the client-side '
  'normaliseUrl() in src/pages/resources/new.astro.';

revoke all on function private.normalise_url(text) from public;

-- ── Enumerations ─────────────────────────────────────────────────────────────────────────

create type public.resource_category as enum (
  'research_tool',
  'educational',
  'formalisation',
  'guidelines_and_policy',
  'community',
  'reading'
);

comment on type public.resource_category is
  'Purpose of a linked resource. ''formalisation'' specifically covers proof assistants and '
  'libraries; ''reading'' is for papers and reports rather than tools.';

create type public.resource_link_status as enum (
  'ok',
  'unreachable',
  'redirected'
);

comment on type public.resource_link_status is
  'Result of the most recent automated link check. Null until the first check runs. '
  '''redirected'' means a 3xx was returned; the URL still resolves but may have moved. '
  '''unreachable'' covers 4xx that are not bot-rejections, 5xx, and timeouts.';

-- ── The table ─────────────────────────────────────────────────────────────────────────────

create table public.resources (
  id           uuid primary key default gen_random_uuid(),

  -- Nullable with ON DELETE SET NULL: the erasure path. A resource whose submitter erased
  -- their account keeps its place in the corpus without a name on it, same as a practice.
  submitter_id uuid references public.profiles (id) on delete set null,

  status public.content_status not null default 'pending',

  title       text not null,
  url         text not null,
  -- Computed by private.normalise_url() in a BEFORE INSERT OR UPDATE trigger.
  -- Never written directly by an API caller.
  url_normalised text not null,

  category public.resource_category not null,

  -- Two text fields with hard caps. The description is what a reader sees in a listing;
  -- the relevance is why a mathematician should care, in the submitter's words.
  description text not null,
  relevance   text not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by  uuid references public.profiles (id) on delete set null,

  -- Set by the monthly link-check workflow, never by a browser caller.
  link_status    public.resource_link_status,
  link_checked_at timestamptz,

  -- Change request from a moderator, same shape as on public.practices.
  moderation_note    text,
  moderation_note_at timestamptz,
  moderation_note_by uuid references public.profiles (id) on delete set null,

  constraint resources_title_length
    check (length(btrim(title)) between 1 and 120),

  constraint resources_url_shape
    check (url ~* '^https?://[^[:space:]]+$'),

  constraint resources_description_length
    check (length(btrim(description)) between 1 and 200),

  constraint resources_relevance_length
    check (length(btrim(relevance)) between 1 and 600),

  constraint resources_deletion_all_or_nothing
    check ((deleted_at is null) = (deleted_by is null)),

  constraint resources_link_check_dated
    check ((link_status is null) = (link_checked_at is null)),

  constraint resources_moderation_note_dated
    check ((moderation_note is null) = (moderation_note_at is null)),

  constraint resources_moderation_note_length
    check (moderation_note is null
           or length(btrim(moderation_note)) between 1 and 1000)
);

comment on table public.resources is
  'Community-curated links, each moderated before publication and checked monthly for '
  'liveness. Duplicate URLs are rejected by the partial unique index on url_normalised.';

comment on column public.resources.url_normalised is
  'Lowercased, scheme-stripped, tracking-parameter-free form of url. Set by trigger; '
  'never written by a caller. The unique index uses this column so UTM variants of the '
  'same link count as one submission.';

comment on column public.resources.link_status is
  'Null until the first monthly link check. Unreachable resources are sorted last on the '
  'listing page and visibly marked; they are never silently hidden.';

comment on column public.resources.moderation_note is
  'Readable by the submitter under "Your submissions". Never shown to the general public; '
  'never shown to other moderators via the queue (they see moderation_note_at to know a '
  'request was made, not what it said).';

-- ── Indexes ──────────────────────────────────────────────────────────────────────────────

-- The unique deduplication constraint. Partial on deleted_at is null: a deleted resource's
-- URL can be resubmitted. Deleted rows are excluded so a hide-then-delete path does not
-- permanently close the URL off.
create unique index resources_url_normalised_unique
  on public.resources (url_normalised)
  where deleted_at is null;

create index resources_published_recent_idx
  on public.resources (created_at desc)
  where status = 'published' and deleted_at is null;

create index resources_category_idx on public.resources (category);

create index resources_pending_idx
  on public.resources (created_at asc)
  where status = 'pending' and deleted_at is null;

create index resources_submitter_idx
  on public.resources (submitter_id)
  where submitter_id is not null;

create index resources_unreachable_idx
  on public.resources (link_checked_at desc)
  where link_status = 'unreachable' and status = 'published' and deleted_at is null;

-- ── URL normalisation trigger ─────────────────────────────────────────────────────────────
-- Computes url_normalised before every insert and every update that touches url.
-- Must fire before the guard trigger (alphabetical order: 'a_' prefix).

create function private.normalise_resource_url()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.url_normalised := private.normalise_url(new.url);
  return new;
end;
$$;

comment on function private.normalise_resource_url() is
  'Sets url_normalised from url before every insert. The guard trigger handles updates.';

revoke all on function private.normalise_resource_url() from public;

create trigger resources_a_normalise_url
  before insert on public.resources
  for each row
  execute function private.normalise_resource_url();

-- ── Column guard trigger ──────────────────────────────────────────────────────────────────
-- Mirrors private.protect_practice_columns() in shape and rationale.
--
-- SECURITY INVOKER, not DEFINER. Inside a DEFINER function current_user is the owner, so
-- the trusted check would see a trusted caller on every browser request, and revert
-- nothing. See CLAUDE.md and the comment on protect_practice_columns.
--
-- What it does:
--   • Always recomputes url_normalised from new.url (handling the edit-while-pending case).
--   • Always sets updated_at.
--   • Trusted callers (service_role, table owner) pass through after those two.
--   • For other callers: reverts id, submitter_id, created_at; reverts status, link columns,
--     and moderation columns; reverts un-delete; freezes content once past pending.

create function private.protect_resource_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  -- Recompute url_normalised from the (possibly changed) url.
  new.url_normalised := private.normalise_url(new.url);
  new.updated_at     := now();

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

  -- Once past pending, the content is fixed. A published resource that could be silently
  -- rewritten after submission is not a record of anything.
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
  'as DEFINER, current_user would always be the owner and the guard would never fire.';

revoke all on function private.protect_resource_columns() from public;

create trigger resources_b_protect_columns
  before update on public.resources
  for each row
  execute function private.protect_resource_columns();

-- ── Row level security ────────────────────────────────────────────────────────────────────

alter table public.resources enable row level security;

-- Anyone reads the published corpus.
create policy resources_select_published
  on public.resources
  for select
  to anon, authenticated
  using (status = 'published' and deleted_at is null);

-- A submitter sees their own work in every state, so a pending submission does not vanish
-- while it waits.
create policy resources_select_own
  on public.resources
  for select
  to authenticated
  using (submitter_id = (select auth.uid()));

-- Moderators see everything, including deleted rows: a report about a resource that was
-- subsequently deleted is still in the queue and must be decidable.
create policy resources_select_moderator
  on public.resources
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  );

-- Insert: confirmed, non-banned, posting under own id, status must start pending.
-- status has no INSERT column grant, so passing status = 'published' is refused at the
-- grant level before this policy is consulted.
create policy resources_insert_own
  on public.resources
  for insert
  to authenticated
  with check (
    submitter_id = (select auth.uid())
    and status = 'pending'
    and deleted_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

-- A submitter may edit their own resource while it is still pending.
create policy resources_update_own_pending
  on public.resources
  for update
  to authenticated
  using  (submitter_id = (select auth.uid()) and status = 'pending' and deleted_at is null)
  with check (submitter_id = (select auth.uid()) and status = 'pending');

-- A submitter may soft-delete their own resource at any status.
-- The WITH CHECK requires the result to be deleted — this policy grants exactly that.
create policy resources_soft_delete_own
  on public.resources
  for update
  to authenticated
  using  (submitter_id = (select auth.uid()) and deleted_at is null)
  with check (submitter_id = (select auth.uid()) and deleted_at is not null);

-- No DELETE policy and no DELETE grant. Soft-delete only, same as practices.

-- ── Grants ───────────────────────────────────────────────────────────────────────────────
-- SELECT to anon and authenticated: the listing and the "your submissions" view.
-- INSERT to authenticated: submitting a resource. No id, status, created_at, updated_at,
-- url_normalised, link_status, link_checked_at, or moderation_note* — browsers do not set
-- those. Grants control whether the endpoint exists; policies then control which rows.

grant select on public.resources to anon, authenticated;

grant insert (
  submitter_id, title, url, category, description, relevance
) on public.resources to authenticated;

grant update (
  status, title, url, category, description, relevance, deleted_at, deleted_by
) on public.resources to authenticated;

-- ── Rate limits ───────────────────────────────────────────────────────────────────────────
-- 5 resources per author per 24 hours, tighter than practices (10). A link submission
-- costs the submitter nothing — a URL and two sentences — and is the most likely spam
-- vector.

insert into private.settings (key, value, note) values (
  'rate_limit_resources_per_day', '5',
  'Resources one submitter may submit per rolling 24 hours. Tighter than practices (10) '
  'because a link submission costs the submitter nothing and is the most likely spam '
  'vector on the site.'
);

-- Add a resources branch to private.enforce_daily_limit().
-- The function is replaced in full; all existing branches are preserved word-for-word.
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
  'private.settings. SECURITY DEFINER so the count includes rows the caller cannot see '
  'and so the threshold itself stays unreadable from a browser. Covers practices, '
  'practice_confirmations, comments, and resources.';

create trigger resources_daily_limit
  before insert on public.resources
  for each row
  execute function private.enforce_daily_limit();

-- ── Moderation ────────────────────────────────────────────────────────────────────────────
-- Two changes: (1) add 'resource' to public.moderation_target, (2) replace
-- public.moderate() to include the resource branch. The replacement preserves all
-- existing branches; the only addition is the elsif block marked with ── Resources ──.

alter type public.moderation_target add value 'resource';

create or replace function public.moderate(
  p_target_type public.moderation_target,
  p_target_id   uuid,
  p_action      public.moderation_action,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor       uuid := (select auth.uid());
  v_role        text;
  v_banned      boolean;
  v_reason      text := nullif(btrim(coalesce(p_reason, '')), '');
  v_author      uuid;
  v_status      text;
  v_target_role text;
  v_user        uuid;
  v_audit       uuid;
begin
  if v_actor is null then
    raise exception 'Moderation needs a signed-in account.'
      using errcode = '42501';
  end if;

  select p.role, p.is_banned
    into v_role, v_banned
    from public.profiles p
   where p.id = v_actor;

  if v_role is null or v_role not in ('moderator', 'admin') or v_banned then
    raise exception 'This account cannot take moderation actions.'
      using errcode = '42501';
  end if;

  if p_action in ('hide', 'request_changes', 'ban') and v_reason is null then
    raise exception
      'Hiding something, sending it back, and banning an account each need a reason. One sentence is enough, and it is kept.'
      using errcode = '23514';
  end if;

  -- ── Practices ─────────────────────────────────────────────────────────────────────

  if p_target_type = 'practice' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.practices x
     where x.id = p_target_id
       and x.deleted_at is null;

    if not found then
      raise exception 'That practice is no longer in the queue. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own submission, and it goes through the same review as anyone else''s. Another moderator has to decide it.'
        using errcode = '42501';
    end if;

    if p_action = 'publish' then
      if v_status <> 'pending' then
        raise exception 'Only a submission still waiting for review can be published.'
          using errcode = '23514';
      end if;

      update public.practices
         set status             = 'published',
             moderation_note    = null,
             moderation_note_at = null,
             moderation_note_by = null
       where id = p_target_id;

    elsif p_action = 'request_changes' then
      if v_status <> 'pending' then
        raise exception
          'Changes can only be asked for while a submission is still waiting for review.'
          using errcode = '23514';
      end if;

      update public.practices
         set moderation_note    = v_reason,
             moderation_note_at = now(),
             moderation_note_by = v_actor
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That practice is already hidden.'
          using errcode = '23514';
      end if;

      update public.practices set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That practice is not hidden.'
          using errcode = '23514';
      end if;

      update public.practices set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a practice.'
        using errcode = '23514';
    end if;

  -- ── Propositions ──────────────────────────────────────────────────────────────────

  elsif p_target_type = 'proposition' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.propositions x
     where x.id = p_target_id;

    if not found then
      raise exception 'That proposition is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own proposition. Promoting it yourself is the shortcut this queue exists to prevent.'
        using errcode = '42501';
    end if;

    if p_action = 'promote' then
      if v_status <> 'proposed' then
        raise exception 'Only a proposed claim can be promoted.'
          using errcode = '23514';
      end if;

      update public.propositions
         set status = 'active', activated_at = now()
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That proposition is already hidden.'
          using errcode = '23514';
      end if;

      update public.propositions
         set status = 'hidden', activated_at = null
       where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That proposition is not hidden.'
          using errcode = '23514';
      end if;

      update public.propositions
         set status = 'proposed', activated_at = null
       where id = p_target_id;

    else
      raise exception 'That action does not apply to a proposition.'
        using errcode = '23514';
    end if;

  -- ── Comments ──────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'comment' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.comments x
     where x.id = p_target_id;

    if not found then
      raise exception 'That comment is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own comment. Delete it as its author instead — that is a different act and it is recorded as one.'
        using errcode = '42501';
    end if;

    if p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That comment is already hidden.'
          using errcode = '23514';
      end if;

      update public.comments set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That comment is not hidden.'
          using errcode = '23514';
      end if;

      update public.comments set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a comment.'
        using errcode = '23514';
    end if;

  -- ── Reports ───────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'report' then
    select r.status::text
      into v_status
      from public.reports r
     where r.id = p_target_id;

    if not found then
      raise exception 'That report is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_status <> 'open' then
      raise exception 'That report has already been dealt with.'
        using errcode = '23514';
    end if;

    if p_action not in ('resolve_report', 'dismiss_report') then
      raise exception 'That action does not apply to a report.'
        using errcode = '23514';
    end if;

    update public.reports
       set status = case when p_action = 'resolve_report'
                         then 'actioned'::public.report_status
                         else 'dismissed'::public.report_status
                    end,
           resolved_at = now(),
           resolved_by = v_actor
     where id = p_target_id;

  -- ── Resources ─────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'resource' then
    select x.submitter_id, x.status::text
      into v_author, v_status
      from public.resources x
     where x.id = p_target_id
       and x.deleted_at is null;

    if not found then
      raise exception 'That resource is no longer in the queue. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own submission, and it goes through the same review as anyone else''s. Another moderator has to decide it.'
        using errcode = '42501';
    end if;

    if p_action = 'publish' then
      if v_status <> 'pending' then
        raise exception 'Only a submission still waiting for review can be published.'
          using errcode = '23514';
      end if;

      update public.resources
         set status             = 'published',
             moderation_note    = null,
             moderation_note_at = null,
             moderation_note_by = null
       where id = p_target_id;

    elsif p_action = 'request_changes' then
      if v_status <> 'pending' then
        raise exception
          'Changes can only be asked for while a submission is still waiting for review.'
          using errcode = '23514';
      end if;

      update public.resources
         set moderation_note    = v_reason,
             moderation_note_at = now(),
             moderation_note_by = v_actor
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That resource is already hidden.'
          using errcode = '23514';
      end if;

      update public.resources set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That resource is not hidden.'
          using errcode = '23514';
      end if;

      update public.resources set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a resource.'
        using errcode = '23514';
    end if;

  -- ── Accounts ──────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'account' then

    if p_action in ('ban', 'unban') then
      if p_target_id = v_actor then
        raise exception 'An account cannot ban itself.'
          using errcode = '42501';
      end if;

      select p.role
        into v_target_role
        from public.profiles p
       where p.id = p_target_id;

      if not found then
        raise exception 'There is no such account.'
          using errcode = '23503';
      end if;

      if v_target_role in ('moderator', 'admin') then
        raise exception
          'Accounts with moderation standing are not banned from this screen. That change needs direct database access, so one compromised session cannot disable the people who would notice.'
          using errcode = '42501';
      end if;

      update public.profiles
         set is_banned = (p_action = 'ban')
       where id = p_target_id;

    elsif p_action = 'erase_account' then
      if v_role <> 'admin' then
        raise exception 'Erasing an account is an admin action.'
          using errcode = '42501';
      end if;

      select d.user_id
        into v_user
        from public.deletion_requests d
       where d.id = p_target_id
         and d.status = 'pending';

      if not found then
        raise exception 'That erasure request is no longer pending. Reload the page.'
          using errcode = '23503';
      end if;

      if v_user = v_actor then
        raise exception
          'Erasing your own account from here would take the record of who did it with it. Ask another admin.'
          using errcode = '42501';
      end if;

      delete from auth.users u where u.id = v_user;

    else
      raise exception 'That action does not apply to an account.'
        using errcode = '23514';
    end if;

  else
    raise exception 'public.moderate() has no rule for target %', p_target_type
      using errcode = '0A000';
  end if;

  -- ── The record ────────────────────────────────────────────────────────────────────

  insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
  values (
    v_actor,
    p_action,
    p_target_type,
    case when p_action = 'erase_account' then null else p_target_id end,
    v_reason
  )
  returning id into v_audit;

  return v_audit;
end;
$$;

comment on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) is
  'The only audited route for a moderation decision. SECURITY DEFINER so it can write rows '
  'the caller cannot, and it authorises on auth.uid() rather than current_user. Covers '
  'practices, propositions, comments, reports, resources, and accounts.';

revoke all on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) from public;
grant execute on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) to authenticated;
