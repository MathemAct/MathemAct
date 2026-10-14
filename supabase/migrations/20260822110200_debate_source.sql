-- What prompted the claim: one external link, or one report from this corpus.
--
-- Optional, and at most one of the two. A debate is a claim rather than a piece of evidence, so
-- this is not a citation and does not belong in `public.citations` — that table records one page
-- referencing another and produces a "referenced by" entry at the far end. This is thinner: it
-- says where the proposer got the idea, and it is read once, above the scale, by somebody
-- deciding whether the claim is well formed.
--
-- Why two columns and not one
-- ---------------------------
-- A link into this corpus and a link out of it are different things and behave differently. A
-- report id can be resolved to a title, checked for existence, and followed to a page that will
-- still be there; an external URL can be none of those. Storing both as text would mean every
-- consumer parsing the string to find out which it was holding, and the first one to get that
-- wrong would render an internal id as a broken external link.
--
-- **At most one**, by CHECK. Two sources is two answers to "what prompted this", and a form that
-- accepted both would have to decide which to show.
--
-- The internal reference is `on delete set null` rather than cascade. A report being erased must
-- not take a claim with it: the claim stands on its own, and losing the pointer is the whole of
-- what should happen.

alter table public.debates
  add column source_url text,
  add column source_report_id uuid references public.reports (id) on delete set null;

comment on column public.debates.source_url is
  'An external link that prompted the claim. https only, no private addresses, at most 500 '
  'characters — validated by private.check_debate_source() to the same rules as a report''s '
  'supporting links. Says nothing about whether it resolves; that is scripts/link-check.mjs.';

comment on column public.debates.source_report_id is
  'A report from this corpus that prompted the claim. SET NULL on delete: erasing a report must '
  'not take the claim with it. Not a citation — public.citations records a reference between two '
  'pages and produces a "referenced by" entry; this only says where the idea came from.';

alter table public.debates
  add constraint debates_one_source
    check (source_url is null or source_report_id is null);

comment on constraint debates_one_source on public.debates is
  'At most one source. Two answers to "what prompted this" is not an answer.';

-- ── Validating the external link ────────────────────────────────────────────────────
-- The same rules as `private.check_report_references()`, and deliberately the same **sentences**:
-- somebody who has met "Supporting links have to start with https://" once should not meet a
-- second, differently worded refusal for the same mistake on another form.
--
-- A trigger rather than a CHECK because the private-address test needs a regexp over a substring
-- of the value, which is expressive enough to belong in a function with the reason written next
-- to it. SECURITY INVOKER: it reads nothing but the row in front of it, and asks nothing about
-- who is running the statement.

create function private.check_debate_source()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_url text := nullif(btrim(coalesce(new.source_url, '')), '');
begin
  -- Normalised on the way in, so that a form submitting a field the user cleared stores a null
  -- rather than an empty string that every consumer then has to test for.
  new.source_url := v_url;

  if v_url is null then
    return new;
  end if;

  if length(v_url) > 500 then
    raise exception
      'That link is longer than 500 characters. Check it is the link you meant.'
      using errcode = '23514';
  end if;

  if v_url !~ '^https://[^[:space:]]+$' then
    raise exception
      'Links have to start with https://. A link nobody can open from outside is not a source.'
      using errcode = '23514';
  end if;

  -- The host, lowercased: everything between the scheme and the first /, ? or #.
  if lower(substring(v_url from '^https://([^/?#]+)')) ~
       '^(localhost|127\.|0\.0\.0\.0|10\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|\[::1\])'
  then
    raise exception
      'That link points at a private address, so it works from one machine only. Link to something publicly readable.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

comment on function private.check_debate_source() is
  'Normalises an empty source_url to null and validates the rest to the same rules, and the same '
  'wording, as a report''s supporting links. https only, no private addresses. Says nothing '
  'about whether the link resolves.';

revoke all on function private.check_debate_source() from public;

-- BEFORE INSERT **and** UPDATE. The wording of a claim freezes at its first rating but the
-- source does not — a proposer who pasted the wrong link should be able to correct it — so the
-- update path is reachable and has to be validated too.
--
-- The name sorts before `debates_protect_columns`, which is what we want: a malformed link is
-- refused as malformed rather than silently reverted by the guard.
create trigger debates_check_source
  before insert or update on public.debates
  for each row
  execute function private.check_debate_source();

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- **In the same file as the column change, which is the standing rule on this table.** INSERT
-- and UPDATE on public.debates are granted per column, so a new column is unwritable until it is
-- named here — and a dropped column takes its grant with it, so any migration that adds, drops
-- or retypes one reissues the GRANT.
--
-- Both columns are writable by the author on both paths. That is different from
-- `agreement_score` and `superseded_by` on public.comments, which are granted to nobody because
-- a trigger sets them and a caller who could name them could lie: here the value *is* the
-- author's to state, and there is nothing for them to lie about that the validation does not
-- already refuse.
--
-- `private.protect_debate_columns()` is deliberately **not** reissued. It freezes `statement`
-- and `area` once the debate has a rating and says nothing about these two, which is the
-- intended behaviour: a source is provenance for the proposer's own thinking, not part of the
-- sentence anybody agreed or disagreed with.

grant insert (source_url, source_report_id) on public.debates to authenticated;
grant update (source_url, source_report_id) on public.debates to authenticated;
