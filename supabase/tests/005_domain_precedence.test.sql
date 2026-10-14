-- Three layers supply domains. This file is about which one wins, and why.
--
-- The rule: longest suffix first, because a more specific domain names a more specific
-- institution and that is a question of correctness. Source breaks ties only between
-- entries of the same length, where it is a question of trust.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(13);

delete from private.manual_domains;

insert into private.ror_institutions (ror_id, name, country_code, country_name) values
  ('0curated1', 'Curated University',        'GB', 'United Kingdom'),
  ('0derived1', 'Derived Institute',         'DE', 'Germany'),
  ('0manual01', 'Manually Added University', 'NL', 'Netherlands'),
  ('0parent01', 'Parent Society',            'DE', 'Germany'),
  ('0childin1', 'Child Institute',           'DE', 'Germany'),
  ('0ghostrec', 'Vanished Institution',      'FR', 'France');

-- Same domain, two sources. Only the authority ordering can decide this.
insert into private.ror_domains (domain, ror_id, source) values
  ('contested.example',  '0curated1', 'ror_domain'),
  ('derived-only.test',  '0derived1', 'ror_website'),
  ('parent.test',        '0parent01', 'ror_website'),
  ('child.parent.test',  '0childin1', 'ror_domain');

insert into private.manual_domains (domain, ror_id, added_by, evidence) values
  ('contested.example', '0manual01', 'test',
   'Fixture proving a manual entry outranks a curated one for the identical domain.'),
  ('manual-only.test', '0manual01', 'test',
   'Fixture proving a manual entry resolves where no ROR domain exists at all.');

-- Authority, at equal length ----------------------------------------------------------

select is(
  (private.match_institution('contested.example')).ror_id, '0manual01'::text,
  'a manual entry outranks a curated ROR domain for the same domain'
);

select is(
  (private.match_institution('contested.example')).source, 'manual'::text,
  'and reports itself as manual'
);

select is(
  (private.match_institution('manual-only.test')).ror_id, '0manual01'::text,
  'a manual entry resolves a domain ROR knows nothing about'
);

select is(
  (private.match_institution('sub.manual-only.test')).ror_id, '0manual01'::text,
  'and a subdomain of it resolves the same way'
);

select is(
  (private.match_institution('derived-only.test')).source, 'ror_website'::text,
  'a website-derived domain reports its provenance honestly'
);

-- Specificity beats authority ---------------------------------------------------------
-- This is the ordering that matters most. The child is only a curated ROR domain and the
-- parent is merely derived, but the child is longer, so the child wins. Getting this
-- backwards would attribute every institute's mail to its parent society.

select is(
  (private.match_institution('child.parent.test')).ror_id, '0childin1'::text,
  'a longer curated domain beats a shorter derived one'
);

select is(
  (private.match_institution('other.parent.test')).ror_id, '0parent01'::text,
  'a sibling with no record of its own still falls back to the derived parent'
);

-- The reverse pairing: a longer *derived* domain beats a shorter *manual* one, because
-- specificity is about which institution the address belongs to, not about who we trust.
insert into private.manual_domains (domain, ror_id, added_by, evidence) values
  ('short.test', '0manual01', 'test',
   'Fixture proving specificity is applied before authority in the ordering.');
insert into private.ror_domains (domain, ror_id, source) values
  ('long.short.test', '0derived1', 'ror_website');

select is(
  (private.match_institution('long.short.test')).ror_id, '0derived1'::text,
  'a longer derived domain beats a shorter manual one'
);

select is(
  (private.match_institution('elsewhere.short.test')).ror_id, '0manual01'::text,
  'while anything else under it still resolves to the manual entry'
);

-- Blocked domains outrank everything --------------------------------------------------
-- A mistaken manual entry must not be able to hand badges to a consumer provider.

insert into private.manual_domains (domain, ror_id, added_by, evidence) values
  ('gmail.com', '0manual01', 'test',
   'Deliberately wrong fixture: the block list must win over a manual mistake.');

select is(
  (private.match_institution('gmail.com')).ror_id, null::text,
  'the block list overrides even a manual entry -- a human mistake is still a mistake'
);

-- A manual entry pointing nowhere -----------------------------------------------------
-- ROR is reloaded wholesale and manual rows have no foreign key, so a manual entry can
-- outlive the record it names. It must fail safe.

insert into private.manual_domains (domain, ror_id, added_by, evidence) values
  ('orphan.test', '0nosuchid', 'test',
   'Fixture: a manual entry naming a ROR record that is not loaded.');

select is(
  (private.match_institution('orphan.test')).ror_id, '0nosuchid'::text,
  'the matcher still returns the identifier it was told about'
);

-- ...and the trigger that consumes it refuses to issue a badge it cannot resolve.
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'someone@orphan.test', '{}'::jsonb, '{}'::jsonb, now(), now());
update auth.users set email_confirmed_at = now()
 where id = '33333333-3333-3333-3333-333333333333';

select is(
  (select institution_ror_id from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null::text,
  'but no badge is issued for an institution that cannot be resolved to a name'
);

select is(
  (select institution_source from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null::text,
  'and no provenance is recorded either'
);

select * from finish();

rollback;
