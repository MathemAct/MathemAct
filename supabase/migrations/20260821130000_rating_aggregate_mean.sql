-- The mean, beside the median, as a secondary figure.
--
-- This reverses the prohibition stated in 20260815160200 and repeated in the comment on
-- `public.rating_aggregate` itself. The original reason was sound and is worth restating,
-- because it is the reason the mean is *secondary* rather than the reason it is absent: on a
-- bimodal distribution the mean reports mild agreement for a community that has split cleanly
-- into two camps, smoothing over the exact thing this corpus exists to make visible.
--
-- What changed is the answer, not the analysis. A mean shown **beside the median and never
-- without the histogram** is a summary statistic a mathematician can read critically; a mean
-- withheld is a number they compute themselves from the histogram, less carefully, and without
-- the caveat the page can put next to it. The rule that carries the original concern is now a
-- display rule: **if the mean ever appears as a card's headline number, on a sort control, or
-- without the histogram beside it, that is the prohibition being violated in the way that
-- mattered.** See docs/decisions.md, 2026-08-15, reversed 2026-08-21.
--
-- Why this has to be in the function and not only in the export
-- ------------------------------------------------------------
-- A debate page shows the distribution in two different ways at two different moments. The
-- nightly export writes it into `data/debate-ratings.json`, and after somebody rates, the
-- browser fetches the live aggregate through `public.debate_ratings`. If the mean existed only
-- in the export, the page would show a mean before the reader answered and lose it the moment
-- they did — or, worse, show two summaries computed from different definitions. The function is
-- the single place either number is computed, which is the same argument the export already
-- makes about coverage: a change to a definition cannot be true on the site and false in the
-- dataset.
--
-- Why DROP and CREATE rather than CREATE OR REPLACE
-- ------------------------------------------------
-- Adding a column to a `returns table (...)` signature changes the function's return type, and
-- `create or replace function` refuses that outright — "cannot change return type of existing
-- function". So the function is dropped and rebuilt, and `public.debate_ratings` with it,
-- because the view depends on it.
--
-- Three things follow from dropping rather than replacing, and all three are easy to lose:
-- DROP takes the function's ACL with it, so the grants are reissued below; Postgres grants
-- EXECUTE to PUBLIC on every new function, so the REVOKE is not optional; and the view loses
-- both its `security_invoker` reloption and its comment, so both are restated. A view over a
-- user-content table without `security_invoker` hands hidden rows to anonymous callers while
-- looking entirely correct in review.
--
-- This is the same sequence 20260817130000 used on this pair, for the same reason.

drop view public.debate_ratings;
drop function public.rating_aggregate(uuid);

create function public.rating_aggregate(p_debate uuid)
returns table (
  -- Eleven counts, index 1 holding the count of score 0 through index 11 holding score 10.
  -- An array rather than eleven columns because every consumer wants it as a sequence:
  -- the histogram component iterates it, and the export carries it as a JSON array.
  histogram integer[],
  median smallint,
  -- Secondary, and never a headline. Two decimal places: enough to distinguish 5.67 from 5.7,
  -- not enough to suggest the underlying self-reported 0-to-10 answers support a third.
  mean numeric,
  -- Everyone who answered, including those who declined. The denominator of coverage.
  total_raters integer,
  -- Those who put a number on it.
  opinion_count integer,
  -- Those who said "no opinion / outside my expertise". A real answer, off the scale.
  no_opinion_count integer,
  -- opinion_count / total_raters, to three places. Flagged as its own number because a
  -- median over four opinions out of forty raters means something very different from a
  -- median over thirty-eight.
  coverage numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    -- Written out rather than generated. A `select ... from generate_series(0, 10)`
    -- subquery here references r.score from the enclosing aggregate query, where it is
    -- ungrouped, and Postgres rejects it: "subquery uses ungrouped column from outer
    -- query". Eleven lines that are obviously correct beat a clever one that is not.
    array[
      count(*) filter (where r.score = 0)::integer,
      count(*) filter (where r.score = 1)::integer,
      count(*) filter (where r.score = 2)::integer,
      count(*) filter (where r.score = 3)::integer,
      count(*) filter (where r.score = 4)::integer,
      count(*) filter (where r.score = 5)::integer,
      count(*) filter (where r.score = 6)::integer,
      count(*) filter (where r.score = 7)::integer,
      count(*) filter (where r.score = 8)::integer,
      count(*) filter (where r.score = 9)::integer,
      count(*) filter (where r.score = 10)::integer
    ],
    -- FILTER rather than relying on how the ordered-set aggregate treats nulls. Being
    -- explicit costs nothing and the alternative is a median that silently includes the
    -- people who declined to give one.
    (percentile_disc(0.5) within group (order by r.score)
       filter (where r.score is not null))::smallint,
    -- The same FILTER for the same reason, and it is doing more work here than on the median.
    -- `avg` ignores nulls by itself, so this changes nothing about the arithmetic — it is here
    -- so that the off-scale answers are visibly excluded rather than excluded by a default
    -- somebody has to remember. Nobody who declined to put a number on the scale is in this
    -- number, which is the whole reason a NULL score is a real row rather than an absence.
    --
    -- Null when nobody has expressed an opinion, exactly like the median. Not zero: zero is a
    -- position on this scale and means strong disagreement.
    round(avg(r.score) filter (where r.score is not null), 2),
    count(*)::integer,
    count(r.score)::integer,
    count(*) filter (where r.score is null)::integer,
    round(count(r.score)::numeric / nullif(count(*), 0), 3)
  from public.ratings r
  where r.debate_id = p_debate
    -- A moderated-away debate reports nothing, even to a caller who names its id.
    and exists (
      select 1
        from public.debates q
       where q.id = p_debate
         and q.status <> 'hidden'
    );
$$;

comment on function public.rating_aggregate(uuid) is
  'Histogram, median, mean and counts for one debate. SECURITY DEFINER so it can count rows '
  'the caller cannot read: individual ratings are visible only to their author. Returns no '
  'value attributable to a person. The mean is secondary — never a headline, never on a sort '
  'control, and never shown without the histogram beside it.';

revoke all on function public.rating_aggregate(uuid) from public;
grant execute on function public.rating_aggregate(uuid) to anon, authenticated;

-- security_invoker is the whole defence here: a view has no row level security of its own, so
-- without it this would hand a hidden debate's histogram to anyone who asked.

create view public.debate_ratings
with (security_invoker = on) as
select
  p.id as debate_id,
  a.histogram,
  a.median,
  a.mean,
  a.total_raters,
  a.opinion_count,
  a.no_opinion_count,
  a.coverage
from public.debates p
-- LATERAL, and a cross join rather than a left one: the function is an aggregate query
-- without GROUP BY, so it returns exactly one row for every debate including those nobody
-- has rated. Those come back as an all-zero histogram with a null median and a null mean,
-- which is the correct description of a debate nobody has answered.
cross join lateral public.rating_aggregate(p.id) a;

comment on view public.debate_ratings is
  'Per debate: the histogram, median, mean and counts. SECURITY INVOKER, so a hidden '
  'debate is absent for anyone who cannot see the debate itself.';

grant select on public.debate_ratings to anon, authenticated;
