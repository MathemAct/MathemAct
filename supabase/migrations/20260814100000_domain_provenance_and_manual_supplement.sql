-- Three sources of truth for "which institution owns this domain", and a record of which
-- one issued each badge.
--
-- Why this exists
-- ---------------
-- Only 41% of active European `education` records in ROR carry a domain at all. That is
-- not a long tail: it is the University of Antwerp, the University of Mannheim, London
-- South Bank, Leiden University, the Max Planck Society, Oberwolfach. Matching against
-- ROR's curated `domains` field alone leaves most European mathematicians with no badge.
--
-- So a domain can now come from three places, in descending order of authority:
--
--   manual        a human added it deliberately, with evidence, in this table
--   ror_domain    ROR's own curated `domains` field
--   ror_website   derived by the loader from the record's website, and only when that
--                 host is claimed by exactly one record in the entire dump
--
-- The uniqueness rule on the third is what makes it safe. Measured against v2.11: of the
-- 101,926 records with no curated domain, 2,400 would derive a host that another record
-- has already curated -- those are the ones that would produce a *wrong* badge -- and
-- 10,663 share a host with another record, which is ambiguous. Both are refused. The
-- remaining 85,911 are unique, and they recover 8,253 of the 9,870 missing European
-- education and facility records.
--
-- Matching precedence
-- -------------------
-- Longest suffix still wins first, because a more specific domain names a more specific
-- institution, and that is a question of correctness rather than of trust. Source breaks
-- ties only between entries of the *same* length. So mis.mpg.de beats mpg.de whatever
-- their sources, and a manual entry beats a derived one for the identical domain.

-- ── Provenance on the ROR-derived domains ───────────────────────────────────────────

alter table private.ror_domains
  add column source text not null default 'ror_domain';

alter table private.ror_domains
  add constraint ror_domains_source_valid
  check (source in ('ror_domain', 'ror_website'));

comment on column private.ror_domains.source is
  'ror_domain: from ROR''s curated domains field. ror_website: derived by the loader from '
  'the record''s website, accepted only when that host is unique across the whole dump.';

-- ── The manual supplement ───────────────────────────────────────────────────────────
-- Deliberately a separate table rather than another `source` value, because these rows
-- have obligations the others do not: somebody put them there, and somebody has to be
-- able to say why.
--
-- No foreign key to private.ror_institutions, on purpose and for a different reason than
-- on profiles. CI reloads that table wholesale; a cascade would silently delete curated
-- human work because ROR reshuffled a record. If the institution is missing at match
-- time the badge simply is not issued -- the trigger already refuses a match it cannot
-- resolve to a name and country -- and the row survives for someone to look at.

create table private.manual_domains (
  domain   text primary key,
  ror_id   text not null,
  added_by text not null,
  added_at timestamptz not null default now(),
  evidence text not null,

  constraint manual_domains_normalised check (
    domain = lower(domain)
    and domain !~ '^\.'
    and domain !~ '\.$'
    and position('.' in domain) > 0
  ),
  constraint manual_domains_ror_id_format check (ror_id ~ '^0[0-9a-z]{8}$'),
  -- A sentence, not a shrug. If nobody can say why a domain is here, it should not be.
  constraint manual_domains_evidence_present check (length(btrim(evidence)) >= 20),
  constraint manual_domains_added_by_present check (length(btrim(added_by)) > 0)
);

comment on table private.manual_domains is
  'Domains added by hand where ROR has none. Highest authority in matching, and the only '
  'table here whose contents are our responsibility rather than ROR''s.';
comment on column private.manual_domains.evidence is
  'Why this mapping is believed correct, in enough detail for someone else to re-check it.';

alter table private.manual_domains enable row level security;

-- Seed: the institutions found missing while loading v2.11. Every one is present and
-- active in ROR with an empty domains array. Five are evidenced by the website ROR itself
-- records; Leiden is not, because ROR lists leiden.edu while its mathematicians publish
-- addresses at math.leidenuniv.nl, which is exactly the case that makes deriving from a
-- website field unsafe to do blindly.
insert into private.manual_domains (domain, ror_id, added_by, evidence) values
  ('mpg.de', '01hhn8329', 'initial seed',
   'Max Planck Society, ROR 01hhn8329, active with an empty domains array. Domain is the '
   'website recorded in that ROR record (mpg.de). Covers every Max Planck institute '
   'subdomain by longest-suffix unless a more specific entry exists.'),

  ('mis.mpg.de', '00ez2he07', 'initial seed',
   'Max Planck Institute for Mathematics in the Sciences, Leipzig, ROR 00ez2he07, active '
   'with an empty domains array. Domain is the website recorded in that ROR record.'),

  ('mpim-bonn.mpg.de', '02dh8ja68', 'initial seed',
   'Max Planck Institute for Mathematics, Bonn, ROR 02dh8ja68, active with an empty '
   'domains array. Domain is the website recorded in that ROR record.'),

  ('mfo.de', '001zbj766', 'initial seed',
   'Mathematical Research Institute of Oberwolfach, ROR 001zbj766, active with an empty '
   'domains array. Domain is the website recorded in that ROR record.'),

  ('mittag-leffler.se', '02z85gz67', 'initial seed',
   'Institut Mittag-Leffler, ROR 02z85gz67, active with an empty domains array. Domain is '
   'the website recorded in that ROR record.'),

  ('leidenuniv.nl', '027bh9e22', 'initial seed',
   'Leiden University, ROR 027bh9e22, active with an empty domains array. ROR records the '
   'website as leiden.edu, which is not the mail domain. Staff of the Mathematical '
   'Institute publish addresses at math.leidenuniv.nl, so leidenuniv.nl is used instead. '
   'Worth re-checking against the university directly before relying on it.');

-- ── Provenance on the badge ─────────────────────────────────────────────────────────
-- Stored but not displayed. The badge claims "an address at this institution's domain was
-- confirmed on this date", which is equally true whichever table supplied the domain. The
-- column exists so that if a derived domain later proves wrong, the badges it issued can
-- be found and revoked rather than guessed at.

alter table public.profiles
  add column institution_source text;

alter table public.profiles
  add constraint profiles_institution_source_valid
  check (institution_source is null
         or institution_source in ('manual', 'ror_domain', 'ror_website'));

-- The all-or-nothing rule now covers five columns rather than four.
alter table public.profiles drop constraint profiles_institution_all_or_nothing;

alter table public.profiles
  add constraint profiles_institution_all_or_nothing check (
    (institution_ror_id is null
      and institution_name is null
      and institution_country is null
      and institution_verified_at is null
      and institution_source is null)
    or
    (institution_ror_id is not null
      and institution_name is not null
      and institution_country is not null
      and institution_verified_at is not null
      and institution_source is not null)
  );

comment on column public.profiles.institution_source is
  'Which layer supplied the domain that issued this badge. System-owned; never displayed.';

-- ── Matching ────────────────────────────────────────────────────────────────────────
-- The return type changes, so the old function is dropped rather than replaced.

drop function if exists private.match_institution(text);

create type private.institution_match as (ror_id text, source text);

create function private.match_institution(email_domain text)
returns private.institution_match
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_domain     text;
  v_labels     text[];
  v_candidates text[];
  v_result     private.institution_match;
begin
  -- Normalise to the form the domain tables are constrained to store: lowercase,
  -- trimmed, no leading or trailing dot. A trailing dot is legal in a fully-qualified
  -- name and would otherwise silently prevent every match.
  v_domain := lower(btrim(coalesce(email_domain, '')));
  v_domain := regexp_replace(v_domain, '^\.+', '');
  v_domain := regexp_replace(v_domain, '\.+$', '');

  if v_domain = '' or position('.' in v_domain) = 0 then
    return null;
  end if;

  if v_domain !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' then
    return null;
  end if;

  v_labels := string_to_array(v_domain, '.');

  -- Every suffix retaining at least two labels; the filter drops the bare TLD. The upper
  -- bound is written out because plpgsql parses an open-ended slice inconsistently when
  -- the lower bound is a query variable, and an empty slice here would turn every badge
  -- off without an error.
  select array_agg(array_to_string(v_labels[i:array_length(v_labels, 1)], '.') order by i)
    into v_candidates
    from generate_subscripts(v_labels, 1) as g(i)
   where array_length(v_labels, 1) - i >= 1;

  if v_candidates is null then
    return null;
  end if;

  -- A consumer or disposable provider, at any depth, resolves to nothing at all. Checked
  -- before the lookup so that neither a bad ROR record nor a mistaken manual entry can
  -- override it.
  if exists (
    select 1 from private.blocked_domains b where b.domain = any (v_candidates)
  ) then
    return null;
  end if;

  -- Longest suffix first; source only breaks a tie between entries of equal length.
  select candidate.ror_id, candidate.source
    into v_result
    from (
      select m.domain, m.ror_id, 'manual'::text as source, 1 as authority
        from private.manual_domains m
       where m.domain = any (v_candidates)
      union all
      select d.domain, d.ror_id, d.source,
             case d.source when 'ror_domain' then 2 else 3 end
        from private.ror_domains d
       where d.domain = any (v_candidates)
    ) as candidate
   order by length(candidate.domain) desc, candidate.authority asc, candidate.ror_id asc
   limit 1;

  return v_result;
end;
$$;

comment on function private.match_institution(text) is
  'Resolve an email domain to a ROR identifier and the layer that supplied the domain. '
  'Longest suffix wins; manual beats curated beats derived at equal length. Returns null '
  'when the domain is blocked, malformed, or unknown. Never uses TLD heuristics.';

revoke all on function private.match_institution(text) from public;

-- ── The callers, updated in the same migration ──────────────────────────────────────
-- match_institution's return type changed, so anything calling it changes with it. Kept
-- in one file so there is never an applied state where the trigger calls a signature that
-- no longer exists.

create or replace function private.sync_institution_from_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_domain  text;
  v_match   private.institution_match;
  v_name    text;
  v_country text;
begin
  -- split_part returns '' rather than null for an address with no '@', which
  -- match_institution rejects.
  v_domain := lower(btrim(split_part(coalesce(new.email, ''), '@', 2)));

  v_match := private.match_institution(v_domain);

  if v_match.ror_id is not null then
    select i.name, i.country_name
      into v_name, v_country
      from private.ror_institutions i
     where i.ror_id = v_match.ror_id;
  end if;

  -- A match that cannot be resolved to a name and country is treated as no match. This is
  -- the path a manual entry takes when it points at a ROR record that has since gone, and
  -- it is deliberately fail-safe: no badge rather than a half-written one.
  if v_match.ror_id is null or v_name is null or v_country is null then
    update public.profiles p
       set institution_ror_id      = null,
           institution_name        = null,
           institution_country     = null,
           institution_verified_at = null,
           institution_source      = null,
           updated_at              = now()
     where p.id = new.id
       and p.institution_ror_id is not null;
  else
    update public.profiles p
       set institution_ror_id      = v_match.ror_id,
           institution_name        = v_name,
           institution_country     = v_country,
           institution_verified_at = now(),
           institution_source      = v_match.source,
           updated_at              = now()
     where p.id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_institution_from_email() from public;

-- The guard gains one column. Everything else about it, including why it is SECURITY
-- INVOKER rather than DEFINER, is unchanged -- see the migration that created it.
create or replace function private.protect_profile_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
  v_is_admin   boolean;
begin
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.profiles'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  v_is_admin := exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and p.role = 'admin'
       and not p.is_banned
  );

  -- Institution columns are reverted for everybody, admins included. They are derived
  -- from a confirmed address and there is no legitimate reason for a human to set them by
  -- hand; an admin path here would make "verified" mean "verified, or an admin said so".
  new.institution_ror_id      := old.institution_ror_id;
  new.institution_name        := old.institution_name;
  new.institution_country     := old.institution_country;
  new.institution_verified_at := old.institution_verified_at;
  new.institution_source      := old.institution_source;
  new.orcid_verified          := old.orcid_verified;

  new.id         := old.id;
  new.created_at := old.created_at;

  if not v_is_admin then
    new.role      := old.role;
    new.is_banned := old.is_banned;
  end if;

  return new;
end;
$$;

revoke all on function private.protect_profile_columns() from public;
