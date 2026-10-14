-- The aggregate: a histogram, a median, and three counts. No mean, here or anywhere.
--
-- Why there is a function under the view
-- --------------------------------------
-- Two requirements pull against each other, and both are right.
--
--   A rating row is readable only by the person who wrote it. Individual ratings are never
--   shown attributed to a name, and the sturdiest way to guarantee that is for the row to
--   be unreadable.
--   The aggregate is readable by everyone.
--
-- A plain view over public.ratings cannot do both. `security_invoker = on` — which every
-- view in the exposed schema must have, or it hands hidden rows to anonymous callers —
-- makes the view read the table as the caller, and the caller can see exactly one row:
-- their own. The histogram would be a histogram of one.
--
-- So the counting happens in a SECURITY DEFINER function that returns aggregates and
-- nothing else. There is no argument by which it can be made to return a row, a user id, or
-- a score attributable to anybody. The view over it stays `security_invoker`, which is
-- still doing real work: it joins public.propositions, so a hidden proposition's aggregate
-- does not appear in a listing to somebody who cannot see the proposition.
--
-- Small numbers are the honest caveat. On a proposition with one rating, the aggregate is
-- that person's score, and anyone who knows they rated it learns what they said. That is
-- true of every aggregate ever computed and is not fixable here; it is why the function
-- refuses hidden propositions and why promotion needs several answers.
--
-- Why the median is percentile_disc
-- ---------------------------------
-- percentile_cont interpolates: on an even number of raters it would return 6.5, which is
-- not a point on the scale and is arrived at by averaging the two middle values. That is a
-- mean of a sort, and this project does not compute one. percentile_disc returns a value
-- somebody actually chose.

create function public.rating_aggregate(p_proposition uuid)
returns table (
  -- Eleven counts, index 1 holding the count of score 0 through index 11 holding score 10.
  -- An array rather than eleven columns because every consumer wants it as a sequence:
  -- the histogram component iterates it, and the export carries it as a JSON array.
  histogram integer[],
  median smallint,
  -- Everyone who answered, including those who declined. The denominator of coverage.
  total_raters integer,
  -- Those who put a number on it.
  opinion_count integer,
  -- Those who said "no opinion / outside my expertise". A real answer, off the scale.
  no_opinion_count integer,
  -- opinion_count / total_raters, to three places. Reported as its own number because a
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
    count(*)::integer,
    count(r.score)::integer,
    count(*) filter (where r.score is null)::integer,
    round(count(r.score)::numeric / nullif(count(*), 0), 3)
  from public.ratings r
  where r.proposition_id = p_proposition
    -- A moderated-away proposition reports nothing, even to a caller who names its id.
    and exists (
      select 1
        from public.propositions q
       where q.id = p_proposition
         and q.status <> 'hidden'
    );
$$;

comment on function public.rating_aggregate(uuid) is
  'Histogram, median and counts for one proposition. SECURITY DEFINER so it can count rows '
  'the caller cannot read: individual ratings are visible only to their author. Returns no '
  'mean, and no value attributable to a person.';

-- Postgres grants EXECUTE to PUBLIC on every new function, so this revoke is not optional
-- even though the grant that follows is wider than usual. Aggregates are public by design.
revoke all on function public.rating_aggregate(uuid) from public;
grant execute on function public.rating_aggregate(uuid) to anon, authenticated;

-- ── The view ────────────────────────────────────────────────────────────────────────

create view public.proposition_ratings
with (security_invoker = on) as
select
  p.id as proposition_id,
  a.histogram,
  a.median,
  a.total_raters,
  a.opinion_count,
  a.no_opinion_count,
  a.coverage
from public.propositions p
-- LATERAL, and a cross join rather than a left one: the function is an aggregate query
-- without GROUP BY, so it returns exactly one row for every proposition including those
-- nobody has rated. Those come back as an all-zero histogram with a null median, which is
-- the correct description of a proposition nobody has answered.
cross join lateral public.rating_aggregate(p.id) a;

comment on view public.proposition_ratings is
  'Per proposition: the histogram, median and counts. SECURITY INVOKER, so a hidden '
  'proposition is absent for anyone who cannot see the proposition itself.';

grant select on public.proposition_ratings to anon, authenticated;
