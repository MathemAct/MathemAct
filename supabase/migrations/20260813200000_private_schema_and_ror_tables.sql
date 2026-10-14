-- Creates the `private` schema and the three lookup tables behind the institutional
-- badge: the ROR institution registry, its domain index, and the list of consumer email
-- domains that must never resolve to an institution.
--
-- Why a separate schema
-- ---------------------
-- Supabase exposes the `public` schema over HTTP by URL. Anything there is defended only
-- by grants and row level security, and a mistake in either is a data leak that looks
-- exactly like a working system. `private` is not in the project's exposed schema list,
-- so PostgREST has no route into it at all — there is no endpoint on which to get the
-- grants wrong.
--
-- These tables are read by private.match_institution() (added in the next migration,
-- SECURITY DEFINER) and written only by the CI job that loads the ROR dump. No browser
-- ever touches them.
--
-- There are deliberately no GRANT statements in this file. That absence is the feature.

create schema if not exists private;

comment on schema private is
  'Server-side only. Not in the exposed schema list, so PostgREST cannot reach it. '
  'Never grant USAGE on this schema to anon or authenticated.';

-- Belt and braces. A schema grants nothing to PUBLIC by default, but being explicit means
-- a future `grant ... to public` elsewhere cannot quietly re-open this one.
revoke all on schema private from public;

-- ── Institutions ────────────────────────────────────────────────────────────────────
-- One row per organisation in the Research Organization Registry (ROR), a CC0 dataset.
-- Loaded wholesale by CI; treated as disposable and reloadable.

create table private.ror_institutions (
  ror_id       text primary key,
  name         text not null,
  country_code text not null,
  country_name text not null,

  -- ROR identifiers are nine characters beginning with 0. Loose on purpose: a stricter
  -- pattern that turns out to be slightly wrong would reject the real dump at load time.
  constraint ror_institutions_id_format check (ror_id ~ '^0[0-9a-z]{8}$'),
  constraint ror_institutions_country_code_format check (country_code ~ '^[A-Z]{2}$'),
  constraint ror_institutions_name_present check (length(btrim(name)) > 0)
);

comment on table private.ror_institutions is
  'ROR organisation records. Source of the institution name and country shown on a badge.';
comment on column private.ror_institutions.country_name is
  'Human-readable country, copied onto a profile as a point-in-time snapshot when a '
  'badge is issued.';

-- ── Domains ─────────────────────────────────────────────────────────────────────────
-- An institution may have several domains, and a domain may legitimately map to more
-- than one record, so the key is the pair.

create table private.ror_domains (
  domain text not null,
  ror_id text not null references private.ror_institutions (ror_id) on delete cascade,

  primary key (domain, ror_id),

  -- Stored lowercase with no leading or trailing dot, because that is the form
  -- match_institution() normalises an email domain into before comparing. A row that
  -- does not satisfy this can never match anything, which is a silent failure, so it is
  -- rejected at write time instead.
  constraint ror_domains_normalised check (
    domain = lower(domain)
    and domain !~ '^\.'
    and domain !~ '\.$'
    and position('.' in domain) > 0
  )
);

-- The primary key already indexes (domain, ror_id) and its leading column serves domain
-- lookups. This narrower index exists because every lookup is `domain = any(...)`
-- returning only ror_id, and a two-column index over a table of a hundred thousand rows
-- is small enough that the extra copy costs less than the planner occasionally choosing
-- a sequential scan during the CI reload.
create index ror_domains_domain_idx on private.ror_domains (domain);

comment on table private.ror_domains is
  'Domain to ROR identifier. Matched by longest suffix, never by TLD heuristics.';

-- ── Blocked domains ─────────────────────────────────────────────────────────────────
-- Consumer mail providers and disposable-address services. A domain listed here, or any
-- subdomain of one, resolves to no institution regardless of what ROR says.
--
-- This is defence in depth rather than the primary mechanism. ROR contains research
-- organisations, so gmail.com would not normally match anything anyway. The list guards
-- against two real failure modes: an erroneous or spam record in an upstream ROR release,
-- and a future institution whose domain happens to be a suffix of a consumer one.

create table private.blocked_domains (
  domain text primary key,
  note   text,

  constraint blocked_domains_normalised check (
    domain = lower(domain) and position('.' in domain) > 0
  )
);

comment on table private.blocked_domains is
  'Consumer and disposable mail domains that must never earn an institutional badge.';

insert into private.blocked_domains (domain, note) values
  -- Google
  ('gmail.com', 'Google'),
  ('googlemail.com', 'Google'),
  -- Microsoft
  ('outlook.com', 'Microsoft'),
  ('outlook.co.uk', 'Microsoft'),
  ('outlook.de', 'Microsoft'),
  ('outlook.fr', 'Microsoft'),
  ('outlook.it', 'Microsoft'),
  ('outlook.es', 'Microsoft'),
  ('hotmail.com', 'Microsoft'),
  ('hotmail.co.uk', 'Microsoft'),
  ('hotmail.fr', 'Microsoft'),
  ('hotmail.de', 'Microsoft'),
  ('hotmail.it', 'Microsoft'),
  ('hotmail.es', 'Microsoft'),
  ('live.com', 'Microsoft'),
  ('live.co.uk', 'Microsoft'),
  ('live.fr', 'Microsoft'),
  ('live.de', 'Microsoft'),
  ('live.it', 'Microsoft'),
  ('live.nl', 'Microsoft'),
  ('msn.com', 'Microsoft'),
  -- Yahoo
  ('yahoo.com', 'Yahoo'),
  ('yahoo.co.uk', 'Yahoo'),
  ('yahoo.fr', 'Yahoo'),
  ('yahoo.de', 'Yahoo'),
  ('yahoo.it', 'Yahoo'),
  ('yahoo.es', 'Yahoo'),
  ('yahoo.ca', 'Yahoo'),
  ('yahoo.co.jp', 'Yahoo'),
  ('yahoo.com.au', 'Yahoo'),
  ('ymail.com', 'Yahoo'),
  ('rocketmail.com', 'Yahoo'),
  ('aol.com', 'Yahoo'),
  -- Apple
  ('icloud.com', 'Apple'),
  ('me.com', 'Apple'),
  ('mac.com', 'Apple'),
  -- Proton
  ('proton.me', 'Proton'),
  ('protonmail.com', 'Proton'),
  ('protonmail.ch', 'Proton'),
  ('pm.me', 'Proton'),
  -- European consumer ISPs and portals, which is where this audience actually is
  ('gmx.com', 'GMX'),
  ('gmx.de', 'GMX'),
  ('gmx.net', 'GMX'),
  ('gmx.at', 'GMX'),
  ('gmx.ch', 'GMX'),
  ('web.de', 'United Internet'),
  ('t-online.de', 'Deutsche Telekom'),
  ('freenet.de', 'Freenet'),
  ('arcor.de', 'Vodafone'),
  ('orange.fr', 'Orange'),
  ('wanadoo.fr', 'Orange'),
  ('free.fr', 'Free'),
  ('sfr.fr', 'SFR'),
  ('laposte.net', 'La Poste'),
  ('libero.it', 'Libero'),
  ('virgilio.it', 'Virgilio'),
  ('tiscali.it', 'Tiscali'),
  ('alice.it', 'Alice'),
  ('seznam.cz', 'Seznam'),
  ('wp.pl', 'Wirtualna Polska'),
  ('o2.pl', 'Wirtualna Polska'),
  ('onet.pl', 'Onet'),
  ('interia.pl', 'Interia'),
  ('bluewin.ch', 'Swisscom'),
  ('telenet.be', 'Telenet'),
  ('ziggo.nl', 'Ziggo'),
  ('xs4all.nl', 'XS4ALL'),
  ('home.nl', 'KPN'),
  ('btinternet.com', 'BT'),
  ('sky.com', 'Sky'),
  ('virginmedia.com', 'Virgin Media'),
  ('mail.ru', 'VK'),
  ('bk.ru', 'VK'),
  ('inbox.ru', 'VK'),
  ('list.ru', 'VK'),
  ('yandex.ru', 'Yandex'),
  ('yandex.com', 'Yandex'),
  ('ukr.net', 'Ukr.net'),
  ('abv.bg', 'ABV'),
  -- North American ISPs
  ('comcast.net', 'Comcast'),
  ('verizon.net', 'Verizon'),
  ('att.net', 'AT&T'),
  ('sbcglobal.net', 'AT&T'),
  ('bellsouth.net', 'AT&T'),
  ('cox.net', 'Cox'),
  ('charter.net', 'Charter'),
  -- Asia-Pacific
  ('qq.com', 'Tencent'),
  ('foxmail.com', 'Tencent'),
  ('163.com', 'NetEase'),
  ('126.com', 'NetEase'),
  ('yeah.net', 'NetEase'),
  ('sina.com', 'Sina'),
  ('sohu.com', 'Sohu'),
  ('aliyun.com', 'Alibaba'),
  ('naver.com', 'Naver'),
  ('hanmail.net', 'Kakao'),
  ('daum.net', 'Kakao'),
  ('nate.com', 'Nate'),
  ('rediffmail.com', 'Rediff'),
  -- Independent mail hosts
  ('mail.com', 'Mail.com'),
  ('zoho.com', 'Zoho'),
  ('fastmail.com', 'Fastmail'),
  ('fastmail.fm', 'Fastmail'),
  ('hey.com', 'Basecamp'),
  ('tutanota.com', 'Tuta'),
  ('tutanota.de', 'Tuta'),
  ('tuta.io', 'Tuta'),
  -- Disposable and throwaway
  ('mailinator.com', 'Disposable'),
  ('guerrillamail.com', 'Disposable'),
  ('10minutemail.com', 'Disposable'),
  ('yopmail.com', 'Disposable'),
  ('temp-mail.org', 'Disposable'),
  ('trashmail.com', 'Disposable'),
  ('sharklasers.com', 'Disposable'),
  ('getnada.com', 'Disposable'),
  ('dispostable.com', 'Disposable'),
  ('maildrop.cc', 'Disposable'),
  ('throwawaymail.com', 'Disposable'),
  ('example.com', 'Reserved by RFC 2606'),
  ('example.org', 'Reserved by RFC 2606'),
  ('example.net', 'Reserved by RFC 2606')
on conflict (domain) do nothing;

-- ── Row level security ──────────────────────────────────────────────────────────────
-- Enabled on every table without exception, per the project rule, even though these
-- three are already unreachable: no exposed schema, no grants, no policies. The table
-- owner and SECURITY DEFINER functions owned by it are unaffected, which is how
-- match_institution() and the CI loader still work.
--
-- Note the absence of FORCE ROW LEVEL SECURITY. Adding it would subject the owner to the
-- policies too, and since there are no policies, that would lock out the loader.

alter table private.ror_institutions enable row level security;
alter table private.ror_domains      enable row level security;
alter table private.blocked_domains  enable row level security;
