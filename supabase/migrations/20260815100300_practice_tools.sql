-- public.practice_tools — which tool, which version, on what date.
--
-- A separate table rather than three columns on practices, because real accounts use more
-- than one tool and the interesting ones use several: a model to draft, a proof assistant
-- to check, a computer algebra system to compute. Flattening that into "tools used" as
-- free text would lose exactly the grouping the corpus exists to support.
--
-- Why the date is mandatory and why it is per tool
-- ------------------------------------------------
-- A practice written against a 2025 model is misleading by 2026, and the interface has to
-- be able to say so without anybody reading the account. That is only possible if the date
-- of use is structured, and it belongs on the tool rather than on the practice because a
-- session that used one model in March and a proof assistant in June is stale in one half
-- and current in the other. The staleness view takes the most recent of them.
--
-- Version is NOT NULL for the same reason. "GPT" with no version is not a reproducible
-- claim about anything, and leaving the field optional guarantees it is usually empty.
-- Where a tool genuinely has no version, the honest answer is a date-stamped string like
-- "web app, undated" -- which is still more than nothing, and visibly so.

create table public.practice_tools (
  id uuid primary key default gen_random_uuid(),

  -- CASCADE, unlike practices.author_id. These rows describe a practice rather than
  -- standing on their own, so a practice that is genuinely destroyed -- which only ever
  -- happens through account erasure or a direct database session -- takes them with it.
  practice_id uuid not null references public.practices (id) on delete cascade,

  tool_name    text not null,
  tool_version text not null,
  used_on      date not null,

  created_at timestamptz not null default now(),

  constraint practice_tools_name_length
    check (length(btrim(tool_name)) between 1 and 120),

  constraint practice_tools_version_length
    check (length(btrim(tool_version)) between 1 and 60),

  -- Lower bound only. The upper bound is "not in the future", which cannot be a CHECK:
  -- current_date is STABLE rather than IMMUTABLE and Postgres refuses it here. It is
  -- enforced by the trigger below instead.
  --
  -- 2015 is generous to the point of being arbitrary, and that is the intent -- it exists
  -- to catch a mistyped year, not to adjudicate when AI assistance in mathematics began.
  constraint practice_tools_used_on_lower_bound
    check (used_on >= date '2015-01-01'),

  -- The same tool at the same version on the same day is one use, however many times it
  -- was opened. Naming all four columns rather than just (practice_id, tool_name) is what
  -- lets an account say "GPT-5 in March, and again in June after it changed".
  constraint practice_tools_distinct
    unique (practice_id, tool_name, tool_version, used_on)
);

comment on table public.practice_tools is
  'Tools used in a practice, with version and date. At least one row per practice, '
  'enforced by a deferred constraint trigger.';
comment on column public.practice_tools.used_on is
  'When the tool was used. Mandatory: the staleness signal on every listing is derived '
  'from the most recent of these.';

create index practice_tools_practice_idx on public.practice_tools (practice_id);
create index practice_tools_name_idx     on public.practice_tools (lower(tool_name));
create index practice_tools_used_on_idx  on public.practice_tools (used_on desc);

-- ── The date cannot be in the future ────────────────────────────────────────────────
-- Worth enforcing rather than shrugging at: listings sort by recency, so a practice dated
-- next year sits at the top of every page until next year arrives.

create function private.check_tool_used_on()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.used_on > current_date then
    raise exception 'A tool cannot have been used in the future: % is after today.', new.used_on
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.check_tool_used_on() from public;

create trigger practice_tools_used_on_not_future
  before insert or update on public.practice_tools
  for each row
  execute function private.check_tool_used_on();

-- ── At least one tool per practice ──────────────────────────────────────────────────
-- A deferred constraint trigger rather than a plain one, because the practice and its
-- tools arrive in the same transaction and the practice row is necessarily inserted first.
-- Checked immediately, every submission would fail on its own first statement.
--
-- SECURITY DEFINER, and here that is about correctness rather than privilege: as INVOKER
-- the count would run under the caller's row level security, and a policy that hid a tool
-- row would make the practice look toolless and fail a submission that was perfectly
-- valid. The function makes no decision about who the caller is, so the DEFINER trap that
-- applies to guards does not apply to it.

create function private.assert_practice_has_tool()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_practice_id uuid;
begin
  if tg_table_name = 'practices' then
    v_practice_id := new.id;
  else
    v_practice_id := old.practice_id;

    -- The parent may have gone in the same statement, taking these rows with it by
    -- cascade. A practice that no longer exists has no invariant left to violate.
    if not exists (
      select 1 from public.practices p where p.id = v_practice_id
    ) then
      return null;
    end if;
  end if;

  if not exists (
    select 1 from public.practice_tools t where t.practice_id = v_practice_id
  ) then
    raise exception
      'A practice must record at least one tool, with its version and the date it was used.'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

comment on function private.assert_practice_has_tool() is
  'Deferred check that a practice has at least one tool row. SECURITY DEFINER so the count '
  'is the true one rather than whatever the caller''s policies leave visible.';

revoke all on function private.assert_practice_has_tool() from public;

create constraint trigger practices_require_a_tool
  after insert on public.practices
  deferrable initially deferred
  for each row
  execute function private.assert_practice_has_tool();

-- The other half. Without this, an author editing a pending draft could remove the last
-- tool and leave a practice with no date of use at all -- which the staleness view would
-- then render as permanently current.
create constraint trigger practice_tools_keep_at_least_one
  after delete on public.practice_tools
  deferrable initially deferred
  for each row
  execute function private.assert_practice_has_tool();

-- ── Row level security ──────────────────────────────────────────────────────────────
-- Every policy here defers to the parent practice by looking it up in public.practices.
-- Those subqueries run under the caller's own row level security, so "a tool row is
-- visible when its practice is" is expressed once, in the practices policies, and cannot
-- drift out of step with them.

alter table public.practice_tools enable row level security;

create policy practice_tools_select_with_parent
  on public.practice_tools
  for select
  to anon, authenticated
  using (
    exists (select 1 from public.practices p where p.id = practice_id)
  );

create policy practice_tools_insert_own_pending
  on public.practice_tools
  for insert
  to authenticated
  with check (
    exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.author_id = (select auth.uid())
         and p.status = 'pending'
         and p.deleted_at is null
    )
  );

create policy practice_tools_update_own_pending
  on public.practice_tools
  for update
  to authenticated
  using (
    exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.author_id = (select auth.uid())
         and p.status = 'pending'
         and p.deleted_at is null
    )
  )
  with check (
    exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.author_id = (select auth.uid())
         and p.status = 'pending'
    )
  );

-- Deleting a tool row is editing a draft, not deleting content, which is why it is allowed
-- here while practices themselves have no DELETE policy at all. The at-least-one trigger
-- still applies, so the last one cannot go.
create policy practice_tools_delete_own_pending
  on public.practice_tools
  for delete
  to authenticated
  using (
    exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.author_id = (select auth.uid())
         and p.status = 'pending'
         and p.deleted_at is null
    )
  );

-- ── Grants ──────────────────────────────────────────────────────────────────────────

grant select on public.practice_tools to anon, authenticated;
grant insert (practice_id, tool_name, tool_version, used_on) on public.practice_tools to authenticated;
grant update (tool_name, tool_version, used_on) on public.practice_tools to authenticated;
grant delete on public.practice_tools to authenticated;
