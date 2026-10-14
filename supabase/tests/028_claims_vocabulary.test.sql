-- The schema says "claim", and nothing in it says "debate".
--
-- 20261012120000 renamed debates to claims and refuses to commit if the old word survives
-- anywhere in the catalogue. That check runs once, at the moment of the rename. This file asks the
-- same questions on every run, so a later migration cannot bring the word back: a function body
-- reissued from a copy taken before the rename, a constraint named after the old table, a comment
-- pasted from an old file. Each of those reads as correct in its own diff and names an object that
-- no longer exists.
--
-- Every assertion is an is_empty() over a query returning the offenders by name, so a failure says
-- what survived rather than how many things did. The pattern is case-insensitive: "Debates" in a
-- comment is the same leftover as debate_id in a column.
--
-- Three historical absence checks elsewhere still carry the word on purpose (013 and 016 assert
-- that promote_debate, ratings_promote_debate and the debate_activation_ratings setting stay
-- gone). They are assertions about the catalogue, not objects in it, so nothing here sees them.
--
-- The first three assertions are a guard against this file passing vacuously: if the schema
-- scoping were wrong, every is_empty() below would pass on an empty catalogue too.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path to extensions, public, pg_catalog;

select plan(15);

-- ── The new names are there ─────────────────────────────────────────────────────────

select ok(
  to_regclass('public.claims') is not null
  and to_regclass('public.claim_tags') is not null
  and to_regclass('public.claim_ratings') is not null,
  'public.claims, public.claim_tags and the view public.claim_ratings exist'
);

select ok(
  'claim' = any (enum_range(null::public.content_kind)::text[])
  and 'claim' = any (enum_range(null::public.moderation_target)::text[]),
  'content_kind and moderation_target both carry the label claim'
);

select ok(
  to_regprocedure('public.answer_claim(uuid, integer, boolean, text, jsonb)') is not null
  and exists (select 1
                from pg_proc p
                join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'submit_claim'),
  'public.answer_claim() and public.submit_claim() exist'
);

-- ── Names ───────────────────────────────────────────────────────────────────────────
-- Every kind of relation, indexes included: an index's own name is renamed like anything else.

select is_empty(
  $$ select n.nspname || '.' || c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and c.relname ~* 'debate' $$,
  'no table, view, index or other relation in public or private is named after a debate'
);

-- Tables and views only. An index has pg_attribute rows of its own, and Postgres does not rewrite
-- their attnames when the table column is renamed, so an index can keep a key column named after
-- whatever the column was called when the index was built. Nothing reads it; 20260817130000
-- explains why it is an artefact rather than a leftover.
select is_empty(
  $$ select n.nspname || '.' || c.relname || '.' || a.attname
       from pg_attribute a
       join pg_class c on c.oid = a.attrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and c.relkind in ('r', 'v', 'm', 'p')
        and a.attnum > 0
        and not a.attisdropped
        and a.attname ~* 'debate' $$,
  'no column of a table or view in public or private is named after a debate'
);

select is_empty(
  $$ select n.nspname || '.' || c.conname
       from pg_constraint c
       join pg_namespace n on n.oid = c.connamespace
      where n.nspname in ('public', 'private')
        and c.conname ~* 'debate' $$,
  'no constraint in public or private is named after a debate'
);

select is_empty(
  $$ select g.tgname || ' on ' || n.nspname || '.' || c.relname
       from pg_trigger g
       join pg_class c on c.oid = g.tgrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and not g.tgisinternal
        and g.tgname ~* 'debate' $$,
  'no trigger in public or private is named after a debate'
);

select is_empty(
  $$ select p.polname || ' on ' || n.nspname || '.' || c.relname
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and p.polname ~* 'debate' $$,
  'no policy in public or private is named after a debate'
);

select is_empty(
  $$ select n.nspname || '.' || p.proname
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private')
        and p.proname ~* 'debate' $$,
  'no function in public or private is named after a debate'
);

-- A parameter name is part of the API: PostgREST calls an RPC with named arguments, so
-- answer_claim(p_debate => …) would be the old vocabulary in every request the site sends.
select is_empty(
  $$ select n.nspname || '.' || p.proname || '(' || array_to_string(p.proargnames, ', ') || ')'
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private')
        and array_to_string(p.proargnames, ',') ~* 'debate' $$,
  'no function in public or private has a parameter named after a debate'
);

select is_empty(
  $$ select n.nspname || '.' || t.typname
       from pg_type t
       join pg_namespace n on n.oid = t.typnamespace
      where n.nspname in ('public', 'private')
        and t.typname ~* 'debate' $$,
  'no type in public or private is named after a debate'
);

select is_empty(
  $$ select n.nspname || '.' || t.typname || '.' || e.enumlabel
       from pg_enum e
       join pg_type t on t.oid = e.enumtypid
       join pg_namespace n on n.oid = t.typnamespace
      where n.nspname in ('public', 'private')
        and e.enumlabel ~* 'debate' $$,
  'no enum label in public or private says debate'
);

-- ── Text that does not follow a rename ──────────────────────────────────────────────
-- A function body is stored as text, so renaming the table it reads leaves the body naming a
-- table that no longer exists. Nothing fails until somebody calls it.

select is_empty(
  $$ select n.nspname || '.' || p.proname
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'private')
        and p.prosrc ~* 'debate' $$,
  'no function body in public or private mentions a debate'
);

-- Comments on every kind of object that lives in, or hangs off something in, public or private:
-- relations and their columns, functions, types, constraints, triggers, policies, and the two
-- schemas themselves. Joined per catalogue rather than read off pg_identify_object(), whose
-- schema is null for triggers and policies because neither catalogue has a namespace column.
select is_empty(
  $$ select pg_describe_object(d.classoid, d.objoid, d.objsubid)
       from pg_description d
      where d.description ~* 'debate'
        and (
             (d.classoid = 'pg_catalog.pg_class'::regclass::oid
              and exists (select 1
                            from pg_class c
                            join pg_namespace n on n.oid = c.relnamespace
                           where c.oid = d.objoid
                             and n.nspname in ('public', 'private')))
          or (d.classoid = 'pg_catalog.pg_proc'::regclass::oid
              and exists (select 1
                            from pg_proc p
                            join pg_namespace n on n.oid = p.pronamespace
                           where p.oid = d.objoid
                             and n.nspname in ('public', 'private')))
          or (d.classoid = 'pg_catalog.pg_type'::regclass::oid
              and exists (select 1
                            from pg_type t
                            join pg_namespace n on n.oid = t.typnamespace
                           where t.oid = d.objoid
                             and n.nspname in ('public', 'private')))
          or (d.classoid = 'pg_catalog.pg_constraint'::regclass::oid
              and exists (select 1
                            from pg_constraint c
                            join pg_namespace n on n.oid = c.connamespace
                           where c.oid = d.objoid
                             and n.nspname in ('public', 'private')))
          or (d.classoid = 'pg_catalog.pg_trigger'::regclass::oid
              and exists (select 1
                            from pg_trigger g
                            join pg_class c on c.oid = g.tgrelid
                            join pg_namespace n on n.oid = c.relnamespace
                           where g.oid = d.objoid
                             and n.nspname in ('public', 'private')))
          or (d.classoid = 'pg_catalog.pg_policy'::regclass::oid
              and exists (select 1
                            from pg_policy p
                            join pg_class c on c.oid = p.polrelid
                            join pg_namespace n on n.oid = c.relnamespace
                           where p.oid = d.objoid
                             and n.nspname in ('public', 'private')))
          or (d.classoid = 'pg_catalog.pg_namespace'::regclass::oid
              and exists (select 1
                            from pg_namespace n
                           where n.oid = d.objoid
                             and n.nspname in ('public', 'private')))
        ) $$,
  'no comment on an object in public or private mentions a debate'
);

-- Constraints, policies, views, defaults and trigger conditions store parsed expressions, so they
-- follow a rename on their own: a comparison with the enum label 'debate' deparses as 'claim'
-- once the label moves. A text literal does not. This is the check that a CHECK or a policy
-- comparing a text column against 'debate' was not left behind to refuse every 'claim'.
select is_empty(
  $$ select 'constraint ' || n.nspname || '.' || c.conname
       from pg_constraint c
       join pg_namespace n on n.oid = c.connamespace
      where n.nspname in ('public', 'private')
        and pg_get_constraintdef(c.oid) ~* 'debate'
     union all
     select 'policy ' || p.polname || ' on ' || n.nspname || '.' || c.relname
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and (coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' '
             || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')) ~* 'debate'
     union all
     select 'view ' || n.nspname || '.' || c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and c.relkind in ('v', 'm')
        and pg_get_viewdef(c.oid) ~* 'debate'
     union all
     select 'default of ' || n.nspname || '.' || c.relname || '.' || a.attname
       from pg_attrdef ad
       join pg_class c on c.oid = ad.adrelid
       join pg_namespace n on n.oid = c.relnamespace
       join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum
      where n.nspname in ('public', 'private')
        and pg_get_expr(ad.adbin, ad.adrelid) ~* 'debate'
     union all
     select 'trigger definition ' || g.tgname || ' on ' || n.nspname || '.' || c.relname
       from pg_trigger g
       join pg_class c on c.oid = g.tgrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('public', 'private')
        and not g.tgisinternal
        and pg_get_triggerdef(g.oid) ~* 'debate' $$,
  'no constraint, policy, view, default or trigger definition in public or private mentions a debate'
);

select * from finish();

rollback;
