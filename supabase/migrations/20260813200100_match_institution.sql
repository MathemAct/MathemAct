-- private.match_institution(email_domain) — resolve an email domain to a ROR identifier
-- by longest-suffix match, or to null.
--
-- This function is the entire basis of the institutional badge. If it can be made to
-- return the wrong identifier, or if a user can influence its input beyond supplying an
-- address they actually control and have confirmed, the badge system is worthless.
--
-- Matching rule
-- -------------
-- A domain matches a ROR domain when it is equal to it, or ends in "." plus it. The
-- longest matching ROR domain wins, so a sub-organisation beats its parent:
--
--     mis.mpg.de   -> Max Planck Institute for Mathematics in the Sciences
--     xyz.mpg.de   -> Max Planck Society        (no specific record, parent matches)
--     maths.ox.ac.uk -> University of Oxford
--
-- Explicitly NOT used: any heuristic on the top-level domain. Rules like "it ends in
-- .edu" or ".ac.uk" fail on exactly the institutions this site exists for — ens.fr,
-- inria.fr, mis.mpg.de, sissa.it, weizmann.ac.il — and would grant badges to any of the
-- thousands of unrelated .edu holders. Matching is only ever against real ROR records.
--
-- Implementation note
-- -------------------
-- The candidate suffixes are enumerated and compared with equality rather than matching
-- with `LIKE '%.' || domain`, which cannot use an index because of the leading wildcard.
-- For maths.ox.ac.uk the candidates are:
--
--     maths.ox.ac.uk, ox.ac.uk, ac.uk
--
-- The bare TLD is deliberately never a candidate: a single-label ROR domain would be a
-- data error, and treating one as a match would hand a badge to an entire country.
--
-- Security
-- --------
-- SECURITY DEFINER, because the caller — a trigger firing on an auth.users update — must
-- read private tables that no application role can reach. search_path is pinned to the
-- empty string and every table is schema-qualified, so nothing here can be resolved
-- through a schema an attacker controls. Built-in functions and operators are left
-- unqualified: pg_catalog is always searched first whether or not it appears in the
-- path, and it is not writable, so those cannot be shadowed.
--
-- EXECUTE is revoked from PUBLIC. Postgres grants it by default, and while the private
-- schema has no USAGE grant to make it reachable anyway, relying on a single lock here
-- would be a mistake.

create or replace function private.match_institution(email_domain text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_domain     text;
  v_labels     text[];
  v_candidates text[];
  v_ror_id     text;
begin
  -- Normalise to the form ror_domains is constrained to store: lowercase, trimmed, no
  -- surrounding whitespace, no leading or trailing dot. A trailing dot is legal in a
  -- fully-qualified name and would otherwise silently prevent every match.
  v_domain := lower(btrim(coalesce(email_domain, '')));
  v_domain := regexp_replace(v_domain, '^\.+', '');
  v_domain := regexp_replace(v_domain, '\.+$', '');

  -- Anything without a dot cannot be an institutional domain.
  if v_domain = '' or position('.' in v_domain) = 0 then
    return null;
  end if;

  -- Reject anything that is not plausibly a hostname before it reaches a query. An
  -- address that got this far has been confirmed by the auth service, so this should be
  -- unreachable; it costs nothing and means a malformed local part can never widen the
  -- candidate set.
  if v_domain !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' then
    return null;
  end if;

  v_labels := string_to_array(v_domain, '.');

  -- Every suffix retaining at least two labels. The filter drops the bare TLD.
  -- The upper bound is written out rather than left open. plpgsql parses `v_labels[i:]`
  -- inconsistently across versions when the lower bound is a query variable, and a slice
  -- that silently comes back empty here would turn every badge off with no error.
  select array_agg(array_to_string(v_labels[i:array_length(v_labels, 1)], '.') order by i)
    into v_candidates
    from generate_subscripts(v_labels, 1) as g(i)
   where array_length(v_labels, 1) - i >= 1;

  if v_candidates is null then
    return null;
  end if;

  -- A consumer or disposable provider, at any depth, resolves to nothing at all. Checked
  -- before the lookup so that a bad upstream ROR record cannot override it.
  if exists (
    select 1
      from private.blocked_domains b
     where b.domain = any (v_candidates)
  ) then
    return null;
  end if;

  -- Longest match wins. The tiebreak on ror_id only matters when two ROR records claim
  -- the same domain, which does occur in the dump; it is there so the answer is stable
  -- across reloads rather than depending on physical row order.
  select d.ror_id
    into v_ror_id
    from private.ror_domains d
   where d.domain = any (v_candidates)
   order by length(d.domain) desc, d.ror_id asc
   limit 1;

  return v_ror_id;
end;
$$;

comment on function private.match_institution(text) is
  'Resolve an email domain to a ROR identifier by longest-suffix match against '
  'private.ror_domains. Returns null when the domain is blocked, malformed, or unknown. '
  'Never uses TLD heuristics.';

revoke all on function private.match_institution(text) from public;
