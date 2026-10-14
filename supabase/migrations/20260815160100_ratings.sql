-- public.ratings — one person's answer to one proposition.
--
-- The scale is 0 to 10, and every rule about it in CLAUDE.md is enforced here rather than
-- trusted to an interface:
--
--   `score` is NULLABLE, and a NULL is a real row. That is the "no opinion / outside my
--   expertise" answer, and it is the single most important design decision on this table.
--   Without it, a mathematician who has never opened Lean answers 5 on a formalisation
--   question and quietly drags every aggregate toward the middle. A NULL row says "I was
--   asked and I decline", which is a different fact from both a 5 and an absence, and it is
--   what makes the coverage figure computable at all.
--
--   One row per person per proposition, by unique constraint. Ratings are editable and no
--   history is kept: the aggregate reports what people currently think, and a table of
--   every opinion anyone ever held would make "the current distribution" ambiguous.
--
--   Nothing here computes a mean, and nothing downstream is given the material to. The
--   aggregate view exposes a histogram, a median and counts. See the migration after this
--   one for why the median is percentile_disc.

create table public.ratings (
  id uuid primary key default gen_random_uuid(),

  proposition_id uuid not null references public.propositions (id) on delete cascade,

  -- CASCADE, unlike propositions.author_id. A rating is one person's answer rather than a
  -- durable contribution: an unattributed one could not be corrected, replaced, or counted
  -- against the one-per-person rule. Erasure removes them, and the aggregate moves.
  user_id uuid not null references public.profiles (id) on delete cascade,

  -- NULL is an answer. See the header.
  score smallint,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint ratings_score_range
    check (score is null or score between 0 and 10),

  constraint ratings_one_per_user
    unique (proposition_id, user_id)
);

comment on table public.ratings is
  'One answer per person per proposition. Editable, no history: the aggregate reports what '
  'people currently think.';
comment on column public.ratings.score is
  '0 to 10, anchors labelled strongly disagree / neutral / strongly agree. NULL is a real '
  'answer meaning "no opinion or outside my expertise" — off the scale, not in the middle '
  'of it.';

create index ratings_proposition_idx on public.ratings (proposition_id);
create index ratings_user_idx        on public.ratings (user_id);

-- ── updated_at ──────────────────────────────────────────────────────────────────────

create function private.touch_rating()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.touch_rating() from public;

create trigger ratings_touch
  before update on public.ratings
  for each row
  execute function private.touch_rating();

-- ── Promotion ───────────────────────────────────────────────────────────────────────
-- A proposition becomes active when enough people have answered it. Not when enough people
-- have *agreed*: the threshold is a count of ratings, including the NULL ones, because what
-- promotion records is that the question turned out to be worth asking. A proposition that
-- fifteen people declined to answer has established something real about itself.
--
-- SECURITY DEFINER because it reads private.settings and writes a row the rater has no
-- business writing. It asks "how many ratings exist", never "who is running this", so the
-- trap that makes a DEFINER guard useless does not apply.

create function private.promote_proposition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_threshold integer;
  v_count     integer;
begin
  select s.value::integer into v_threshold
    from private.settings s
   where s.key = 'proposition_activation_ratings';

  -- An unconfigured threshold means "do not promote", never "promote everything". The
  -- proposition stays proposed and a moderator can still promote it by hand.
  if v_threshold is null then
    return null;
  end if;

  select count(*) into v_count
    from public.ratings r
   where r.proposition_id = new.proposition_id;

  if v_count >= v_threshold then
    update public.propositions p
       set status = 'active', activated_at = now()
     where p.id = new.proposition_id
       and p.status = 'proposed';
  end if;

  return null;
end;
$$;

comment on function private.promote_proposition() is
  'Promotes a proposed proposition once it reaches the rating count in private.settings. '
  'Counts NULL scores too: promotion records that the question was worth asking.';

revoke all on function private.promote_proposition() from public;

create trigger ratings_promote_proposition
  after insert on public.ratings
  for each row
  execute function private.promote_proposition();

-- The proposition guard references this table, so its trigger is created here — the
-- function was written in the previous migration, where the reason it is SECURITY INVOKER
-- is set out.
create trigger propositions_protect_columns
  before update on public.propositions
  for each row
  execute function private.protect_proposition_columns();

-- ── Row level security ──────────────────────────────────────────────────────────────
-- The rule that shapes everything else: **a rating row is visible only to the person who
-- wrote it.** Individual ratings are never shown attributed to a name, so the safest place
-- to enforce that is the place where an attributed row could be read at all.
--
-- This is why the aggregate cannot be a plain view over this table. See the next migration.

alter table public.ratings enable row level security;

create policy ratings_select_own
  on public.ratings
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Same three conditions as every other write on this site. A proposition that has been
-- hidden stops accepting ratings; a proposed one accepts them, which is how it gets
-- promoted.
create policy ratings_insert_own
  on public.ratings
  for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
    and exists (
      select 1
        from public.propositions q
       where q.id = proposition_id
         and q.status <> 'hidden'
    )
  );

create policy ratings_update_own
  on public.ratings
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- No DELETE policy and no DELETE grant, deliberately. Changing your mind is an update, and
-- withdrawing entirely is a score of NULL — which is a real answer rather than an absence,
-- and keeps you counted in the coverage figure as somebody who was asked.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Nothing to anon: an anonymous reader has no rating to read and none to write.

grant select on public.ratings to authenticated;
grant insert (proposition_id, user_id, score) on public.ratings to authenticated;
grant update (score) on public.ratings to authenticated;
