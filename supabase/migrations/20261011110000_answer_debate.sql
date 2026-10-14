-- Answering a debate means taking a position *and* giving a reason for it, in one step.
--
-- Until now a rating could be saved on its own, and endorsing or writing came afterwards as an
-- optional extra. Most answers therefore arrived with no reason attached, and the position groups
-- filled with counts nobody explained — the opposite of *a debate is a map of positions, not a
-- feed of comments*. From here on, somebody joining a debate they did not propose does two things,
-- and does them together:
--
--   1. puts themselves on the scale, and
--   2. either endorses at least one existing contribution, or writes their own.
--
-- What is exempt, and why
-- -----------------------
-- **"No opinion, or outside my expertise."** A NULL score needs no reason. Demanding prose from
-- somebody declining to answer would push them to pick a number instead, and a 5 chosen to avoid
-- writing a paragraph is exactly the corruption the off-scale answer exists to prevent.
--
-- **The proposer.** public.submit_debate() inserts their rating beside the claim and the rationale,
-- which is their reason. Same "your own answer is not an answer" exemption the wording freeze uses.
--
-- **Changing a score to another score.** A position change stays an outcome to record, with a new
-- contribution invited and not required (see 20260821120300). The one update that *is* checked is
-- NULL to a score: that is taking a position for the first time, and without the check the rule is
-- a two-step bypass — answer "no opinion", then move.
--
-- **Ratings that already exist.** Nothing here reads or rewrites a row written before this file.
-- The checks fire on INSERT, and on the NULL-to-score UPDATE only.
--
-- Why a deferred constraint, and why an RPC
-- -----------------------------------------
-- It is a rule about rows in three tables, and row level security only ever sees one row. And the
-- order is forced: the comment trigger (20260821120000) and the endorsement insert policy
-- (20260821120200) both require the rating to exist *at row time*, so the rating must be written
-- first and cannot be checked until the reason has followed it. A constraint trigger deferred to
-- commit is the shape for that — the same one `practices_require_a_tool` uses, and the same
-- conclusion docs/decisions.md records for submit_report(): a deferred constraint makes submission
-- one RPC, because PostgREST runs each request in its own transaction.
--
-- public.answer_debate() is that RPC. **SECURITY INVOKER, like submit_debate()**: every insert runs
-- under the caller's own policies — the ban clauses, confirmed email, the author not endorsing their
-- own contribution, the daily comment limit — so it authorises nothing, and the count of ban
-- clauses stays at nine. Any refusal rolls the rating back with it. Nothing is ever half-saved.

-- ── The check ───────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER, and this is the safe direction of the trap rather than an instance of it: it
-- asks *which rows exist*, never *who is running the statement*. It must be DEFINER for
-- correctness. public.comment_endorsements is readable only by the endorser, and an INVOKER count
-- would be whatever the caller's policies left visible — the same reasoning as
-- private.assert_practice_has_tool(). A private-schema function, so it adds no Security Advisor
-- warning.

create function private.assert_rating_has_contribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_debate_id uuid;
  v_user_id   uuid;
  v_score     smallint;
begin
  -- Re-read rather than trust NEW. This runs at commit, and the row may have changed since the
  -- statement that queued the check — an answer of 7 revised to "no opinion" in the same
  -- transaction is a "no opinion", and is exempt.
  select r.debate_id, r.user_id, r.score
    into v_debate_id, v_user_id, v_score
    from public.ratings r
   where r.id = new.id;

  -- Gone in the same transaction, which only an erasure cascade does. No row, no rule.
  if not found then
    return null;
  end if;

  -- "No opinion" needs no reason. See the header.
  if v_score is null then
    return null;
  end if;

  -- The proposer. Their claim and its rationale are the reason.
  if exists (
    select 1 from public.debates d
     where d.id = v_debate_id
       and d.author_id = v_user_id
  ) then
    return null;
  end if;

  -- A contribution of their own on this debate. Deleted ones do not count: there is no reason
  -- left in them to stand behind the position.
  if exists (
    select 1 from public.comments c
     where c.parent_type = 'debate'
       and c.parent_id   = v_debate_id
       and c.author_id   = v_user_id
       and c.deleted_at is null
  ) then
    return null;
  end if;

  -- Or an endorsement of somebody else's. Either kind: "I agree with the position, but not this
  -- reason" is still somebody saying where their reason is not, which is a contribution.
  if exists (
    select 1
      from public.comment_endorsements e
      join public.comments c on c.id = e.comment_id
     where e.user_id     = v_user_id
       and c.parent_type = 'debate'
       and c.parent_id   = v_debate_id
  ) then
    return null;
  end if;

  -- The wording is matched by src/lib/debates.ts, which shows it beside the form. Change both.
  raise exception
    'Endorse a contribution that captures your view, or write your own, to record your position.'
    using errcode = '23514';
end;
$$;

comment on function private.assert_rating_has_contribution() is
  'Deferred check that a rating with a score is accompanied by a contribution or an endorsement '
  'on the same debate. Exempt: no-opinion answers and the proposer. SECURITY DEFINER so the '
  'endorsement lookup is not filtered by own-rows-only RLS; it asks which rows, never who.';

revoke all on function private.assert_rating_has_contribution() from public;

create constraint trigger ratings_require_a_contribution
  after insert on public.ratings
  deferrable initially deferred
  for each row
  execute function private.assert_rating_has_contribution();

-- Score-to-score updates never fire this, so changing your mind stays free.
create constraint trigger ratings_position_needs_a_contribution
  after update on public.ratings
  deferrable initially deferred
  for each row
  when (old.score is null and new.score is not null)
  execute function private.assert_rating_has_contribution();

-- ── The RPC ─────────────────────────────────────────────────────────────────────────

create function public.answer_debate(
  p_debate        uuid,
  -- integer, although public.ratings.score is smallint. Same reason as submit_debate's p_score:
  -- a smallint parameter makes answer_debate(..., 8, ...) fail with "function does not exist".
  p_score         integer default null,
  -- True for "no opinion, or outside my expertise". Two parameters rather than a nullable score,
  -- for the reason submit_debate's header gives: NULL is a real answer here, and "the form was
  -- not filled in" must not look like it.
  p_off_scale     boolean default false,
  -- A new contribution, or null.
  p_body          text    default null,
  -- `[{"comment_id": uuid, "kind": "captures_my_view" | "agree_position_not_reason"}, …]`
  p_endorsements  jsonb   default '[]'::jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user       uuid := (select auth.uid());
  v_score      smallint;
  v_comment_id uuid;
  v_item       jsonb;
  v_target     uuid;
  v_kind       public.endorsement_kind;
begin
  if not p_off_scale and p_score is null then
    raise exception
      'Choose a point on the scale, or say that you have no opinion — that is a real answer and '
      'it is recorded as one.'
      using errcode = '23514';
  end if;

  if p_off_scale and p_score is not null then
    raise exception
      'That is both a score and no opinion. Choose one.'
      using errcode = '23514';
  end if;

  if jsonb_typeof(coalesce(p_endorsements, '[]'::jsonb)) <> 'array' then
    raise exception 'Endorsements must be a list.' using errcode = '22023';
  end if;

  v_score := case when p_off_scale then null else p_score end;

  -- ── The position, first ─────────────────────────────────────────────────────────────
  -- First because everything after it requires it at row time. UPDATE then INSERT rather than
  -- ON CONFLICT, so this touches only the granted `score` column and only the existing
  -- policies — the same reason saveRating() in the browser did it in two requests.
  update public.ratings r
     set score = v_score
   where r.debate_id = p_debate
     and r.user_id   = v_user;

  if not found then
    insert into public.ratings (debate_id, user_id, score)
    values (p_debate, v_user, v_score);
  end if;

  -- ── A contribution of their own ───────────────────────────────────────────────────
  -- comments_set_agreement_score stamps the position just written, and
  -- comments_supersede_previous links any earlier contribution forward to this one.
  if nullif(btrim(coalesce(p_body, '')), '') is not null then
    insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
    values ('debate', p_debate, v_user, null, btrim(p_body))
    returning id into v_comment_id;
  end if;

  -- ── Endorsements ──────────────────────────────────────────────────────────────────
  -- Each one under comment_endorsements_insert_own, which refuses the caller's own contribution,
  -- a deleted one, and one on another debate's thread — and which can see the rating above,
  -- because it is this transaction's own row. One that already exists changes kind instead.
  for v_item in select * from jsonb_array_elements(coalesce(p_endorsements, '[]'::jsonb))
  loop
    v_target := (v_item ->> 'comment_id')::uuid;
    v_kind   := (v_item ->> 'kind')::public.endorsement_kind;

    -- The endorsement policy checks that the contribution is on *a* debate the caller answered.
    -- This checks it is on *this* one, so one call cannot satisfy the rule for one debate with
    -- an endorsement on another.
    if not exists (
      select 1 from public.comments c
       where c.id          = v_target
         and c.parent_type = 'debate'
         and c.parent_id   = p_debate
    ) then
      raise exception
        'One of those contributions is not on this debate. Reload the page and try again.'
        using errcode = '23514';
    end if;

    update public.comment_endorsements e
       set kind = v_kind
     where e.comment_id = v_target
       and e.user_id    = v_user;

    if not found then
      insert into public.comment_endorsements (comment_id, user_id, kind)
      values (v_target, v_user, v_kind);
    end if;
  end loop;

  return v_comment_id;
end;
$$;

comment on function public.answer_debate is
  'Records the caller''s position on a debate together with its reason — a new contribution, '
  'endorsements of existing ones, or both — in one transaction. The deferred constraint '
  'ratings_require_a_contribution refuses a scored first answer without a reason. SECURITY '
  'INVOKER: every insert runs under the caller''s own policies, and this function authorises '
  'nothing.';

revoke all on function public.answer_debate from public;
grant execute on function public.answer_debate to authenticated;
