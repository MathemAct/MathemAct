-- A proposer's own position does not freeze their own claim.
--
-- This is a prerequisite for 20260822110300, which requires the proposer to place themselves on
-- the scale as part of creating the debate — and without it that requirement would silently take
-- something away.
--
-- `private.protect_debate_columns()` freezes `statement` and `area` as soon as **any** rating
-- exists, which was right while the first rating was always somebody else's: people answered the
-- sentence in front of them, and an author who could reword it afterwards would be reassigning
-- their agreement to a claim they never saw. From 20260822110300 onwards a rating always exists
-- from the moment the debate does — the proposer's own — so the freeze would engage on creation
-- and a proposer could never fix a typo in their own claim. Nobody would have agreed to anything
-- yet; the rule would be protecting a reader who does not exist.
--
-- **Your own answer is not an answer**, which is the same rule `private.mark_report_answered()`
-- already states in as many words for reports: "An author correcting their own report in the
-- thread should not thereby lose the ability to correct the report." The condition becomes a
-- rating by somebody *other than* the author, and the window closes the moment one arrives.
--
-- The whole function is reissued rather than patched, per the standing rule for this project's
-- guards. It is otherwise identical to 20260817130000's version — which is itself
-- 20260815200300's body, the one with the moderator branch removed because `public.moderate()`
-- is the only route to `status`. `create or replace` is safe: the signature takes no arguments
-- and never has.
--
-- SECURITY INVOKER, and load-bearing rather than conventional: inside a DEFINER function
-- `current_user` is the function's owner, so the trusted check below would pass on every browser
-- request and the guard would revert nothing while reading exactly like one that works.

create or replace function private.protect_debate_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.debates'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  -- Promotion and hiding are decisions, and decisions are logged. public.moderate() is the
  -- only route to either.
  new.status       := old.status;
  new.activated_at := old.activated_at;

  -- The wording is fixed once **somebody else** has rated it. People rated the sentence in front
  -- of them, and an author who could reword it afterwards would be reassigning their agreement
  -- to a claim they never saw.
  --
  -- `is distinct from` and not `<>`: `author_id` is nullable — erasure detaches a debate from its
  -- author rather than deleting it — and on a detached debate `<>` would evaluate to NULL for
  -- every rating, the EXISTS would find nothing, and the wording of a claim dozens of people had
  -- answered would come unfrozen. There is no route by which an author-less debate can be
  -- updated by a browser, since the ownership policy also fails, but a guard that depends on
  -- another rule holding is a guard with a footnote.
  if exists (
    select 1
      from public.ratings r
     where r.debate_id = old.id
       and r.user_id is distinct from old.author_id
  ) then
    new.statement := old.statement;
    new.area      := old.area;
  end if;

  return new;
end;
$$;

comment on function private.protect_debate_columns() is
  'Freezes id, author, dates and status, and freezes the wording once somebody other than the '
  'author has rated. SECURITY INVOKER: inside a DEFINER function current_user is the owner, so '
  'the trusted check would admit every browser request.';

revoke all on function private.protect_debate_columns() from public;

-- The trigger is not recreated. `debates_protect_columns` — renamed from
-- `propositions_protect_columns` by 20260817130000, which renamed triggers as well as tables —
-- already points at this name, and `create or replace` has replaced the body under it.
