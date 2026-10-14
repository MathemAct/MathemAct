-- The reasoning behind a claim is capped at 500 characters, down from 2000.
--
-- **The cap is the mechanism, not a formatting preference.** An opening post that runs to two
-- thousand characters is the thing this section exists to prevent: it turns a claim somebody
-- can answer into an essay somebody has to agree or disagree with in aggregate, and the
-- distribution that comes out is a distribution over whatever each reader took the essay to be
-- arguing. Nothing else reliably prevents it. Guidance in the form asks nicely and is ignored
-- by exactly the people whose rationale most needs shortening; a CHECK is not.
--
-- Five hundred is about a paragraph — enough to say why the claim is contested and what the
-- strongest case against it is, and not enough to make the case itself. The case belongs in a
-- contribution, where it carries the position it was argued from and can be endorsed or
-- answered. A rationale cannot: it sits above the scale, it is read before anybody answers, and
-- it is the one piece of prose on the page that nobody can reply to.
--
-- The column is also relabelled, in the form and in the object comment: "why it is worth
-- asking" invited a case for asking the question, which is not the same thing as the reasoning
-- behind the claim and is what produced the long ones.

-- ── Anything already over the new cap ───────────────────────────────────────────────
-- Refused rather than truncated. Cutting somebody's writing to make a migration apply is not a
-- migration's business, and a rationale trimmed mid-sentence is worse than one that is too
-- long. If this raises, the rows are untouched and the decision about what to do with them is a
-- person's.
--
-- The corpus has one debate and its rationale is under 200 characters, so this is expected to
-- pass. It is here because a migration that only works against the database it was written on
-- is not finished.

do $$
declare
  v_count integer;
begin
  select count(*)
    into v_count
    from public.debates
   where rationale is not null
     and length(btrim(rationale)) > 500;

  if v_count > 0 then
    raise exception
      'There are % debate(s) whose reasoning is longer than the new 500-character cap. '
      'Nothing has been changed. They can be found with "select id, length(btrim(rationale)) '
      'from public.debates where length(btrim(rationale)) > 500 order by 2 desc", and each '
      'wants shortening by hand or by its author.', v_count
      using errcode = '23514';
  end if;
end;
$$;

-- ── The cap ─────────────────────────────────────────────────────────────────────────
-- Dropped and re-added rather than altered: Postgres has no ALTER CONSTRAINT for a CHECK
-- expression, so replacing one is always these two statements.
--
-- The name is `debates_rationale_length` and **not** `propositions_rationale_length`, which is
-- what 20260815160000 called it. 20260817130000 renamed constraints as well as tables, in a
-- loop over pg_constraint — so the creating migration is the wrong place to read a constraint
-- name from, exactly as it is the wrong place to read a function signature from. The name is
-- kept across this change, because it is the name that appears in an error and in the tests.

alter table public.debates
  drop constraint debates_rationale_length;

alter table public.debates
  add constraint debates_rationale_length
    check (rationale is null or length(btrim(rationale)) between 1 and 500);

comment on constraint debates_rationale_length on public.debates is
  'The reasoning behind the claim, at most 500 characters. The cap is the only thing that '
  'reliably stops an opening post becoming an essay, which is what makes a claim unanswerable.';

comment on column public.debates.rationale is
  'The reasoning behind the claim: why it is contested, and the strongest case against it. Read '
  'before anybody answers and repliable by nobody, which is why it is short. The case itself '
  'belongs in a contribution, where it carries a position and can be endorsed.';

-- No grant change. `rationale` already has both its INSERT and UPDATE column grants from
-- 20260815160000, and a CHECK is not a privilege — the constraint narrows what may be written
-- to a column the caller could already write.
