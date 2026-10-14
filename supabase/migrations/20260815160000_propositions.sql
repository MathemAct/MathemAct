-- public.propositions — a single well-formed claim that can be agreed with.
--
-- The unit the community argues about, kept deliberately narrow. "AI-assisted literature
-- search should be disclosed in papers" is a proposition; "AI is good for mathematics" is
-- not, because there is no answer to it that means anything. Ratings attach here and
-- nowhere else — never to a practice, never to a comment — so that a number on this site
-- always refers to a claim somebody wrote down and can be quoted.
--
-- The statement cap is 200 characters and is the main thing enforcing that. A claim that
-- does not fit in a sentence is usually two claims, and two claims sharing one rating
-- produce an aggregate that means nothing: half the disagreement is with the first half of
-- the sentence and there is no way to tell which half.

create type public.proposition_status as enum (
  -- Suggested by a member and open for rating, but not yet part of the record.
  'proposed',
  -- Promoted, either by a moderator or by reaching the rating threshold below.
  'active',
  -- Moderated away. Still exists; readable by nobody but its author and a moderator.
  'hidden'
);

comment on type public.proposition_status is
  'Lifecycle of a proposition. Distinct from content_status: a proposition is rateable while '
  'proposed, which has no equivalent for a practice.';

create table public.propositions (
  id uuid primary key default gen_random_uuid(),

  -- Nullable, ON DELETE SET NULL, exactly as on practices: erasure detaches rather than
  -- destroys. A proposition people have rated cannot vanish because its author left —
  -- the ratings would be orphaned and the record of the disagreement lost.
  author_id uuid references public.profiles (id) on delete set null,

  statement text not null,
  rationale text,

  status public.proposition_status not null default 'proposed',

  -- The same vocabulary as practices, reused rather than reinvented. A proposition about
  -- disclosure in papers is a `writing` question; one about proof checking is `research`.
  -- Two enums of the same five words would drift the first time one of them was widened.
  area public.practice_area not null,

  created_at   timestamptz not null default now(),
  activated_at timestamptz,

  -- One claim, in a sentence. See the header for why this cap is doing real work.
  constraint propositions_statement_length
    check (length(btrim(statement)) between 10 and 200),

  constraint propositions_rationale_length
    check (rationale is null or length(btrim(rationale)) between 1 and 2000),

  -- A proposition is active exactly when it has an activation date. Without this the two
  -- drift and "when did this become part of the record" stops being answerable.
  constraint propositions_activated_iff_active
    check ((status = 'active') = (activated_at is not null))
);

comment on table public.propositions is
  'A single claim that can be agreed with. The only thing ratings attach to.';
comment on column public.propositions.statement is
  'One claim, 200 characters. Two claims sharing a rating produce an aggregate nobody can '
  'interpret.';
comment on column public.propositions.activated_at is
  'When it became part of the record, by moderator promotion or by reaching the rating '
  'threshold in private.settings.';

create index propositions_active_idx
  on public.propositions (activated_at desc)
  where status = 'active';

create index propositions_proposed_idx
  on public.propositions (created_at desc)
  where status = 'proposed';

create index propositions_author_idx
  on public.propositions (author_id)
  where author_id is not null;

-- ── The activation threshold ────────────────────────────────────────────────────────
-- A row rather than a literal, for the same reason the rate limits are: this is a number
-- that wants adjusting once real traffic arrives, and the adjustment should be one UPDATE
-- by whoever is watching rather than a migration, a review and a deploy.

insert into private.settings (key, value, note) values
  ('proposition_activation_ratings', '5',
   'How many ratings promote a proposed proposition to active without a moderator. Low on '
   'purpose: the point of promotion is that enough people cared to answer, not that a '
   'quorum agreed. A moderator can promote or hide one at any time regardless.');

-- ── The guard ───────────────────────────────────────────────────────────────────────
-- SECURITY INVOKER, for the same reason as every other guard here: inside a DEFINER
-- function current_user is the owner, so the check below would see a trusted caller on
-- every browser request and revert nothing.

create function private.protect_proposition_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted   boolean;
  v_is_moderator boolean;
begin
  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.propositions'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  v_is_moderator := exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and p.role in ('moderator', 'admin')
       and not p.is_banned
  );

  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  if not v_is_moderator then
    new.status       := old.status;
    new.activated_at := old.activated_at;

    -- The wording is fixed once anyone has rated it. People rated the sentence in front of
    -- them, and an author who could reword it afterwards would be reassigning their
    -- agreement to a claim they never saw.
    if exists (select 1 from public.ratings r where r.proposition_id = old.id) then
      new.statement := old.statement;
      new.area      := old.area;
    end if;
  end if;

  return new;
end;
$$;

comment on function private.protect_proposition_columns() is
  'Reverts writes the caller does not own. SECURITY INVOKER: as DEFINER, current_user would '
  'always be the owner and the guard would never fire.';

revoke all on function private.protect_proposition_columns() from public;

-- The trigger is created in the ratings migration, because the function above references
-- public.ratings and that table does not exist yet. plpgsql resolves names at run time, so
-- the function body is accepted now and would only fail if it fired before the table
-- existed — which the deferred trigger creation prevents.

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.propositions enable row level security;

-- Proposed and active are both public. A proposed one has to be readable to be rateable,
-- and rating is how it gets promoted.
create policy propositions_select_visible
  on public.propositions
  for select
  to anon, authenticated
  using (status <> 'hidden');

create policy propositions_select_own
  on public.propositions
  for select
  to authenticated
  using (author_id = (select auth.uid()));

create policy propositions_select_moderator
  on public.propositions
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

-- Same three conditions as posting a practice: confirmed address, not banned, under your
-- own name. Everything starts proposed; there is no way in as active.
create policy propositions_insert_own
  on public.propositions
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and status = 'proposed'
    and activated_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

-- An author may correct their own wording while nobody has rated it. The guard above is
-- what enforces the "while nobody has rated it" half; this policy governs the row.
create policy propositions_update_own
  on public.propositions
  for update
  to authenticated
  using (author_id = (select auth.uid()) and status = 'proposed')
  with check (author_id = (select auth.uid()) and status = 'proposed');

create policy propositions_update_moderator
  on public.propositions
  for update
  to authenticated
  using (
    exists (
      select 1 from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  );

-- No DELETE policy and no DELETE grant. Hiding is the removal path; deleting would take
-- everybody's ratings with it.

-- ── Grants ──────────────────────────────────────────────────────────────────────────

grant select on public.propositions to anon, authenticated;

-- status and activated_at are absent: a proposition cannot be born active.
grant insert (author_id, statement, rationale, area) on public.propositions to authenticated;

-- status and activated_at are present here and restricted by the moderator policy and the
-- guard, exactly as on practices — moderators reach PostgREST as the same `authenticated`
-- role as everyone else, so no column grant can distinguish them.
grant update (statement, rationale, area, status, activated_at)
  on public.propositions to authenticated;
