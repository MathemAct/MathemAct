-- public.submit_debate() — proposing a claim means stating a position on it.
--
-- **Somebody unwilling to say where they stand should not be setting the question.** That is the
-- rule this function exists to make real, and it cannot be made real in a policy: it is a
-- statement about two rows in two tables, and row level security only ever sees one row at a
-- time. Nor can the client be trusted to do both writes — an insert into public.debates followed
-- by an insert into public.ratings leaves, on any failure of the second, a debate whose proposer
-- never answered it. Which is precisely the thing being forbidden, arrived at by accident.
--
-- So it is one function and one transaction. The proposer's position becomes the first entry in
-- the distribution, which is also the honest ordering: the person who wrote the claim is the
-- first person to have taken a view on it.
--
-- Why SECURITY INVOKER
-- -------------------
-- Same as `public.submit_report()`, and worth being explicit because a function that writes to
-- two tables looks like it wants elevation. It does not. Every insert below runs under the
-- caller's own row level security — `debates_insert_own`, `ratings_insert_own`,
-- `debate_tags_insert_own_unanswered` — so **this function authorises nothing.** It is a
-- transaction boundary and a required-field check, and the policies remain the only thing
-- deciding who may write. A DEFINER version would have to restate all three sets of conditions,
-- and the restatement is where they drift.
--
-- The consequence to keep in mind: a caller who inserts into public.debates directly still can,
-- and gets a debate with no position on it. That is not a hole this function could close — the
-- policies allow it and must, because the guard trigger and the wording freeze both need an
-- author who can write their own row. What this function does is make the *supported* path the
-- one that produces a well-formed debate, and make the form unable to produce anything else.
--
-- Why the position is two parameters
-- ----------------------------------
-- Because NULL is a real answer here and "nothing chosen" has to be distinguishable from it. On
-- this scale a NULL score is "no opinion, or outside my expertise" — a genuine position stored
-- on a genuine row, and the whole reason the eleven points have a twelfth group beside them. A
-- single nullable score parameter would collapse that into "the caller did not fill the field
-- in", and the function would either refuse the people the off-scale option exists for or accept
-- an empty submission as a declared non-opinion. Both are worse than one extra boolean.

create function public.submit_debate(
  p_statement       text,
  p_area            public.report_area,
  -- integer, although public.ratings.score is smallint. Postgres will not implicitly narrow an
  -- integer literal to smallint while resolving which function to call, so a smallint parameter
  -- makes submit_debate(..., 8, ...) fail with "function does not exist" — a message that sends
  -- you looking for a missing migration rather than a missing cast. Same reasoning, and the same
  -- comment, as submit_report's p_author_confidence. The narrowing happens on INSERT, where it
  -- is unambiguous, and the range is checked there by ratings_score_range.
  p_score           integer default null,
  -- True when the proposer chose "no opinion, or outside my expertise". See the header: this is
  -- what makes a declined answer distinguishable from an unanswered form.
  p_off_scale       boolean default false,
  p_rationale       text    default null,
  p_tag_codes       text[]  default '{}',
  p_source_url      text    default null,
  p_source_report   uuid    default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- ── The position, which is the point of this function ─────────────────────────────
  -- Checked before anything is written, so the refusal names the field rather than arriving as
  -- a constraint violation from a table the form does not mention.

  if not p_off_scale and p_score is null then
    raise exception
      'Say where you stand on your own claim. Proposing a debate means taking a position on it — '
      'and "no opinion, or outside my expertise" is one of the answers, if that is the honest one.'
      using errcode = '23514';
  end if;

  if p_off_scale and p_score is not null then
    raise exception
      'That is both a score and no opinion. Choose one.'
      using errcode = '23514';
  end if;

  -- Belt as well as braces: debates_one_source says the same thing, and this says it in a
  -- sentence about the form.
  if p_source_url is not null and p_source_report is not null then
    raise exception
      'Give one source or the other, not both — a link out, or a report from this corpus.'
      using errcode = '23514';
  end if;

  -- ── The claim ─────────────────────────────────────────────────────────────────────
  -- `author_id` is set from auth.uid() rather than taken as a parameter, so there is no
  -- argument by which this function can post under somebody else's name. `debates_insert_own`
  -- would refuse it anyway; not offering the parameter means nobody has to check.

  insert into public.debates (
    author_id, statement, rationale, area, source_url, source_report_id
  )
  values (
    (select auth.uid()),
    btrim(p_statement),
    nullif(btrim(coalesce(p_rationale, '')), ''),
    p_area,
    nullif(btrim(coalesce(p_source_url, '')), ''),
    p_source_report
  )
  returning id into v_id;

  -- ── The proposer's own position ───────────────────────────────────────────────────
  -- `p_score` when they put a number on it, NULL when they declined. Both are real rows; the
  -- difference between them is the difference the twelfth group exists to record.

  insert into public.ratings (debate_id, user_id, score)
  values (v_id, (select auth.uid()), case when p_off_scale then null else p_score end);

  -- ── Tags ──────────────────────────────────────────────────────────────────────────
  -- Matched by code rather than by id, so the client never has to know the uuids — and an
  -- unknown or retired code is **silently dropped** rather than failing a submission somebody
  -- spent ten minutes on. Retiring a tag between page load and submit is rare, and losing a tag
  -- is a far smaller harm than losing the claim. Copied deliberately from submit_report, wording
  -- included, because it is the same trade.
  --
  -- Inserted after the rating, which means `debate_tags_insert_own_unanswered` sees exactly one
  -- rating by the time it runs: the proposer's own. That policy therefore tests for a rating by
  -- somebody *else*, and 20260822110250 puts the same condition in the wording freeze. Had either
  -- tested for any rating at all, this insert would be refused on every submission — a whole
  -- feature dead on arrival, in a way no single migration reads as wrong.

  insert into public.debate_tags (debate_id, tag_id)
  select v_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;

  return v_id;
end;
$$;

comment on function public.submit_debate is
  'Creates a debate and the proposer''s own rating in one transaction, so a claim cannot exist '
  'without its author having taken a position on it. SECURITY INVOKER: every insert runs under '
  'the caller''s own policies, and this function authorises nothing.';

-- DROP takes a function's ACL with it and Postgres grants EXECUTE to PUBLIC on every new one, so
-- neither line here is optional. migrate.yml asserts in production that nothing private is
-- reachable by a browser role.
revoke all on function public.submit_debate from public;
grant execute on function public.submit_debate to authenticated;
