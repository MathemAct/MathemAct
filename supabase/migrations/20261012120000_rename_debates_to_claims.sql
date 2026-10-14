-- Renames debates to claims throughout the schema. The section the site calls *Debates* is now
-- *Opinions*, and one item in it is a *claim*:
--
--   public.debates, public.debate_tags   -> public.claims, public.claim_tags
--   debate_id (ratings, claim_tags, rating_changes) -> claim_id
--   public.debate_ratings                -> public.claim_ratings
--   public.debate_status                 -> public.claim_status
--   'debate' in content_kind and moderation_target -> 'claim'
--   posted_debate, rated_debate, debate_promoted, debate_rated -> …_claim, claim_…
--   public.submit_debate(), public.answer_debate(p_debate) -> submit_claim(), answer_claim(p_claim)
--   rating_aggregate(p_debate)           -> rating_aggregate(p_claim)
--   every debates_* / debate_tags_* index, constraint, policy and trigger -> claims_* / claim_tags_*
--
-- Why "claim" and not "opinion", when the section is called Opinions. The collection and the
-- row have different names, as the network does: the route is /network/ and a row is an entry in
-- public.network_entries. Here the route is /opinions/ and a row is a claim. "Opinion" was also
-- already taken, by rating_aggregate's opinion_count and no_opinion_count — the number of scored
-- positions and the number of off-scale ones — and a no-opinion answer on an opinion is not a
-- sentence anybody should have to read in a column header.
--
-- Why rename the schema rather than only the interface. Same reason as 20260817130000, which
-- renamed propositions to debates: the schema is the corpus's public surface. It is what
-- scripts/export.mjs selects from, what the dataset's values are named after ('claim' is now a
-- parentType in comments.json), and what anyone querying a dump reads.
--
-- How. Exactly the method 20260817130000 used, and for the same reasons: tables, columns, enum
-- labels and types are renamed in place, which policies, CHECKs and views follow on their own
-- because they store parsed expressions. Index, constraint, policy and trigger names are renamed
-- off the catalogues. Function bodies are text and do not follow, so every function whose body
-- names a debate is reissued in full from its latest definition with the vocabulary substituted
-- and nothing else changed. Object comments are rewritten the same way. The last statement
-- refuses to commit if the word survives anywhere in the catalogue.
--
-- Trigger order does not move. BEFORE ROW triggers fire alphabetically, and the two on this table
-- keep their order: claims_check_source still sorts before claims_protect_columns, as
-- debates_check_source did before debates_protect_columns. On ratings, ratings_activity_insert
-- still sorts before ratings_mark_claim_answered.
--
-- Nothing about behaviour changes. If this migration alters what a single policy admits or what
-- a single trigger raises — other than the word "debate" becoming "claim" in four error
-- messages — it is wrong.

-- ── 0. Object comments, captured before anything moves ──────────────────────────────────
-- Three objects are dropped below (the view, the aggregate and answer_debate) and a drop takes
-- the object's comment with it. So every comment that names a debate, or sits on an object whose
-- name does, is copied out now under its old identity and written back in section 8 under the
-- new one. One mechanism for the renamed, the recreated and the merely mentioned.

create temporary table renamed_comments as
select o.type, o.identity, d.description
  from pg_description d
  cross join lateral pg_identify_object(d.classoid, d.objoid, d.objsubid) o
 where (o.schema in ('public', 'private')
        -- Triggers and policies belong to a table, not a schema, and pg_identify_object reports
        -- no schema for them, nor for the two schemas themselves.
        or o.type in ('trigger', 'policy')
        or (o.type = 'schema' and o.identity in ('public', 'private')))
   and (d.description ~* 'debate' or o.identity ~* 'debate');

-- ── 1. Enum labels and types ────────────────────────────────────────────────────────────
-- A label rename does not touch stored rows: the value keeps its identity and only its name
-- moves, which is why no CHECK or policy comparing against these labels needs attention. Unlike
-- `add value`, a rename is usable in the same transaction.

alter type public.content_kind      rename value 'debate'          to 'claim';
alter type public.moderation_target rename value 'debate'          to 'claim';

alter type public.activity_kind     rename value 'posted_debate'   to 'posted_claim';
alter type public.activity_kind     rename value 'rated_debate'    to 'rated_claim';
alter type public.activity_kind     rename value 'debate_promoted' to 'claim_promoted';
alter type public.activity_kind     rename value 'debate_rated'    to 'claim_rated';

alter type public.debate_status rename to claim_status;

-- ── 2. Tables and the columns that name their parent ────────────────────────────────────
-- Column-level grants follow a rename. They do not follow a drop and re-add, which is why
-- nothing here is dropped.

alter table public.debates     rename to claims;
alter table public.debate_tags rename to claim_tags;

alter table public.ratings        rename column debate_id to claim_id;
alter table public.claim_tags     rename column debate_id to claim_id;
alter table public.rating_changes rename column debate_id to claim_id;

-- ── 3. What has to be dropped ───────────────────────────────────────────────────────────
-- rating_aggregate and answer_debate each have a parameter called p_debate, and CREATE OR
-- REPLACE cannot rename a parameter. The browser passes answer_claim's arguments by name, so the
-- name is part of the interface. The view goes first because it calls the aggregate. All three
-- are recreated in sections 6 and 7 with their grants.

drop view public.debate_ratings;
drop function public.rating_aggregate(uuid);
drop function public.answer_debate(uuid, integer, boolean, text, jsonb);

-- ── 4. Function names ───────────────────────────────────────────────────────────────────
-- ALTER FUNCTION … RENAME keeps the ACL and every trigger that fires the function, so these
-- need no grants. Their bodies are replaced in section 6. submit_debate is renamed rather than
-- recreated because none of its parameter names changes.

alter function private.activity_on_debate()     rename to activity_on_claim;
alter function private.check_debate_source()    rename to check_claim_source;
alter function private.mark_debate_answered()   rename to mark_claim_answered;
alter function private.protect_debate_columns() rename to protect_claim_columns;
alter function public.submit_debate             rename to submit_claim;

-- ── 5. Index, constraint, policy and trigger names ──────────────────────────────────────
-- Off the catalogues, as 20260817130000 did. One substitution covers every name: "debates"
-- contains "debate", so debates_one_source becomes claims_one_source and debate_tags_pkey
-- becomes claim_tags_pkey without a second pair.
--
-- Constraints before plain indexes: renaming a constraint renames the index behind it, and
-- renaming that index directly would leave the constraint pointing at a differently named
-- object.

do $$
declare
  v_row record;
begin
  -- Constraints.
  for v_row in
    select c.conname, n.nspname, t.relname
      from pg_constraint c
      join pg_class     t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname in ('public', 'private')
       and position('debate' in c.conname) > 0
  loop
    execute format('alter table %I.%I rename constraint %I to %I',
                   v_row.nspname, v_row.relname, v_row.conname,
                   replace(v_row.conname, 'debate', 'claim'));
  end loop;

  -- Indexes that are not behind a constraint.
  for v_row in
    select i.relname, n.nspname
      from pg_class     i
      join pg_namespace n on n.oid = i.relnamespace
     where n.nspname in ('public', 'private')
       and i.relkind = 'i'
       and position('debate' in i.relname) > 0
       and not exists (select 1 from pg_constraint c where c.conindid = i.oid)
  loop
    execute format('alter index %I.%I rename to %I',
                   v_row.nspname, v_row.relname, replace(v_row.relname, 'debate', 'claim'));
  end loop;

  -- Policies.
  for v_row in
    select p.polname, n.nspname, t.relname
      from pg_policy    p
      join pg_class     t on t.oid = p.polrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname in ('public', 'private')
       and position('debate' in p.polname) > 0
  loop
    execute format('alter policy %I on %I.%I rename to %I',
                   v_row.polname, v_row.nspname, v_row.relname,
                   replace(v_row.polname, 'debate', 'claim'));
  end loop;

  -- Triggers, constraint triggers included. This is also what keeps
  -- 027_rebuild_on_write.test.sql true: it requires tgname = relname || '_note_content_changed',
  -- and claims_note_content_changed and claim_tags_note_content_changed are both made here.
  for v_row in
    select g.tgname, n.nspname, t.relname
      from pg_trigger   g
      join pg_class     t on t.oid = g.tgrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname in ('public', 'private')
       and not g.tgisinternal
       and position('debate' in g.tgname) > 0
  loop
    execute format('alter trigger %I on %I.%I rename to %I',
                   v_row.tgname, v_row.nspname, v_row.relname,
                   replace(v_row.tgname, 'debate', 'claim'));
  end loop;
end $$;

-- ── 6. Function bodies ──────────────────────────────────────────────────────────────────
-- Reissued because a function body is text and does not follow a rename. Each is the definition
-- that was last applied, named above it, with "debate" replaced by "claim" — code, literals and
-- comments alike — and nothing else changed. The four error messages that said "debate" now say
-- "claim"; the rest of each is byte-identical, and ANSWER_NEEDS_A_REASON, which src/lib/claims.ts
-- repeats, never contained the word.
--
-- Every statement is CREATE OR REPLACE, which keeps each function's ACL, comment and triggers.
-- The two dropped in section 3 are created fresh and granted in section 7.

-- private.activity_label, from 20260818120000_activity.sql.
create or replace function private.activity_label(
  p_type public.moderation_target,
  p_id   uuid
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_label  text;
  v_parent public.content_kind;
  v_id     uuid := p_id;
  v_type   public.moderation_target := p_type;
begin
  if v_type = 'comment' then
    select c.parent_type, c.parent_id
      into v_parent, v_id
      from public.comments c
     where c.id = p_id;

    if v_parent is null then
      return null;
    end if;

    v_type := private.as_target(v_parent);
  end if;

  if v_type = 'report' then
    select x.title into v_label from public.reports x where x.id = v_id;
  elsif v_type = 'claim' then
    select x.statement into v_label from public.claims x where x.id = v_id;
  elsif v_type = 'entry' then
    select x.title into v_label from public.network_entries x where x.id = v_id;
  end if;

  return v_label;
end;
$$;

-- private.activity_on_citation, from 20260818120100_activity_triggers.sql.
create or replace function private.activity_on_citation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.moderation_target := private.as_target(new.target_type);
  v_label  text := private.activity_label(v_target, new.target_id);
  v_owner  uuid;
begin
  perform private.log_activity(
    new.created_by, 'cited', new.created_by, v_target, new.target_id, null, v_label
  );

  if new.target_type = 'report' then
    select x.author_id into v_owner from public.reports x where x.id = new.target_id;
  else
    select x.author_id into v_owner from public.claims x where x.id = new.target_id;
  end if;

  perform private.log_activity(
    v_owner, 'content_cited', new.created_by, v_target, new.target_id, null, v_label
  );

  return null;
end;
$$;

-- private.activity_on_comment, from 20260818120100_activity_triggers.sql.
create or replace function private.activity_on_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.moderation_target := private.as_target(new.parent_type);
  v_label  text := private.activity_label(v_target, new.parent_id);
  v_owner  uuid;
begin
  perform private.log_activity(
    new.author_id, 'commented', new.author_id, v_target, new.parent_id, new.id, v_label
  );

  if new.in_reply_to is not null then
    select c.author_id into v_owner
      from public.comments c
     where c.id = new.in_reply_to;

    perform private.log_activity(
      v_owner, 'comment_reply', new.author_id, v_target, new.parent_id, new.id, v_label
    );

    return null;
  end if;

  if new.parent_type = 'report' then
    select x.author_id into v_owner from public.reports x where x.id = new.parent_id;
  else
    select x.author_id into v_owner from public.claims x where x.id = new.parent_id;
  end if;

  perform private.log_activity(
    v_owner, 'content_commented', new.author_id, v_target, new.parent_id, new.id, v_label
  );

  return null;
end;
$$;

-- private.activity_on_claim (was private.activity_on_debate), from 20260818120100_activity_triggers.sql.
create or replace function private.activity_on_claim()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_activity(
    new.author_id, 'posted_claim', new.author_id, 'claim', new.id, null, new.statement
  );

  return null;
end;
$$;

-- private.activity_on_rating, from 20260818120100_activity_triggers.sql.
create or replace function private.activity_on_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_label text;
begin
  select x.author_id, x.statement
    into v_owner, v_label
    from public.claims x
   where x.id = new.claim_id;

  perform private.log_activity(
    new.user_id, 'rated_claim', new.user_id, 'claim', new.claim_id, null, v_label
  );

  -- The "not your own act" test is made here rather than left to private.log_activity(),
  -- which cannot make it: that function compares the actor to the subject, and the actor
  -- passed below is null precisely so the row cannot name the rater. Without this line an
  -- author rating their own claim would be told that somebody rated it.
  if new.score is not null and v_owner is distinct from new.user_id then
    perform private.log_activity(
      v_owner, 'claim_rated', null, 'claim', new.claim_id, null, v_label
    );
  end if;

  return null;
end;
$$;

-- private.as_target, from 20260818120000_activity.sql.
create or replace function private.as_target(p_kind public.content_kind)
returns public.moderation_target
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_kind
    when 'report'  then 'report'::public.moderation_target
    when 'claim'   then 'claim'::public.moderation_target
    when 'comment' then 'comment'::public.moderation_target
  end;
$$;

-- private.assert_rating_has_contribution, from 20261011110000_answer_debate.sql.
create or replace function private.assert_rating_has_contribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_user_id   uuid;
  v_score     smallint;
begin
  -- Re-read rather than trust NEW. This runs at commit, and the row may have changed since the
  -- statement that queued the check — an answer of 7 revised to "no opinion" in the same
  -- transaction is a "no opinion", and is exempt.
  select r.claim_id, r.user_id, r.score
    into v_claim_id, v_user_id, v_score
    from public.ratings r
   where r.id = new.id;

  -- Gone in the same transaction, which only an erasure cascade does. No row, no rule.
  if not found then
    return null;
  end if;

  -- "No opinion" needs no reason. See the header.
  if v_score is null then
    return null;
  end if;

  -- The proposer. Their claim and its rationale are the reason.
  if exists (
    select 1 from public.claims d
     where d.id = v_claim_id
       and d.author_id = v_user_id
  ) then
    return null;
  end if;

  -- A contribution of their own on this claim. Deleted ones do not count: there is no reason
  -- left in them to stand behind the position.
  if exists (
    select 1 from public.comments c
     where c.parent_type = 'claim'
       and c.parent_id   = v_claim_id
       and c.author_id   = v_user_id
       and c.deleted_at is null
  ) then
    return null;
  end if;

  -- Or an endorsement of somebody else's. Either kind: "I agree with the position, but not this
  -- reason" is still somebody saying where their reason is not, which is a contribution.
  if exists (
    select 1
      from public.comment_endorsements e
      join public.comments c on c.id = e.comment_id
     where e.user_id     = v_user_id
       and c.parent_type = 'claim'
       and c.parent_id   = v_claim_id
  ) then
    return null;
  end if;

  -- The wording is matched by src/lib/claims.ts, which shows it beside the form. Change both.
  raise exception
    'Endorse a contribution that captures your view, or write your own, to record your position.'
    using errcode = '23514';
end;
$$;

-- private.backfill_activity, from 20260818140000_activity_backfill.sql.
create or replace function private.backfill_activity()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before integer;
  v_row    record;
  v_target public.moderation_target;
  v_label  text;
  v_owner  uuid;
begin
  select count(*) into v_before from public.activity;

  -- Reports, claims and entries: what each person posted.
  for v_row in select id, author_id, title, created_at from public.reports order by created_at
  loop
    perform private.log_activity(
      v_row.author_id, 'posted_report', v_row.author_id, 'report', v_row.id,
      null, v_row.title, v_row.created_at
    );
  end loop;

  for v_row in select id, author_id, statement, created_at from public.claims order by created_at
  loop
    perform private.log_activity(
      v_row.author_id, 'posted_claim', v_row.author_id, 'claim', v_row.id,
      null, v_row.statement, v_row.created_at
    );
  end loop;

  for v_row in
    select id, submitter_id, title, created_at from public.network_entries order by created_at
  loop
    perform private.log_activity(
      v_row.submitter_id, 'posted_entry', v_row.submitter_id, 'entry', v_row.id,
      null, v_row.title, v_row.created_at
    );
  end loop;

  -- Comments: the writer's own row, and exactly one notification — to the replied-to
  -- comment's author for a reply, to the content's author for a top-level comment.
  for v_row in
    select id, parent_type, parent_id, author_id, in_reply_to, created_at
      from public.comments
     order by created_at
  loop
    v_target := private.as_target(v_row.parent_type);
    v_label  := private.activity_label(v_target, v_row.parent_id);

    perform private.log_activity(
      v_row.author_id, 'commented', v_row.author_id, v_target, v_row.parent_id,
      v_row.id, v_label, v_row.created_at
    );

    if v_row.in_reply_to is not null then
      select c.author_id into v_owner from public.comments c where c.id = v_row.in_reply_to;

      perform private.log_activity(
        v_owner, 'comment_reply', v_row.author_id, v_target, v_row.parent_id,
        v_row.id, v_label, v_row.created_at
      );
    else
      if v_row.parent_type = 'report' then
        select x.author_id into v_owner from public.reports x where x.id = v_row.parent_id;
      else
        select x.author_id into v_owner from public.claims x where x.id = v_row.parent_id;
      end if;

      perform private.log_activity(
        v_owner, 'content_commented', v_row.author_id, v_target, v_row.parent_id,
        v_row.id, v_label, v_row.created_at
      );
    end if;
  end loop;

  -- Ratings. The author is never told who, and an explicit "no opinion" is not a rating.
  for v_row in
    select r.claim_id, r.user_id, r.score, r.created_at, d.author_id, d.statement
      from public.ratings r
      join public.claims d on d.id = r.claim_id
     order by r.created_at
  loop
    perform private.log_activity(
      v_row.user_id, 'rated_claim', v_row.user_id, 'claim', v_row.claim_id,
      null, v_row.statement, v_row.created_at
    );

    if v_row.score is not null and v_row.author_id is distinct from v_row.user_id then
      perform private.log_activity(
        v_row.author_id, 'claim_rated', null, 'claim', v_row.claim_id,
        null, v_row.statement, v_row.created_at
      );
    end if;
  end loop;

  -- Still-works confirmations. Public, so the person is named.
  for v_row in
    select c.report_id, c.user_id, c.created_at, p.author_id, p.title
      from public.report_confirmations c
      join public.reports p on p.id = c.report_id
     order by c.created_at
  loop
    perform private.log_activity(
      v_row.user_id, 'confirmed_report', v_row.user_id, 'report', v_row.report_id,
      null, v_row.title, v_row.created_at
    );

    perform private.log_activity(
      v_row.author_id, 'report_confirmed', v_row.user_id, 'report', v_row.report_id,
      null, v_row.title, v_row.created_at
    );
  end loop;

  -- Flags. The flagger's own row only, now as then.
  for v_row in
    select id, subject_type, subject_id, flagger_id, created_at from public.flags
     order by created_at
  loop
    perform private.log_activity(
      v_row.flagger_id, 'flagged', v_row.flagger_id, 'flag', v_row.id, null,
      private.activity_label(private.as_target(v_row.subject_type), v_row.subject_id),
      v_row.created_at
    );
  end loop;

  -- Citations. Both rows point at the cited piece rather than at the citing one.
  for v_row in
    select target_type, target_id, created_by, created_at from public.citations
     order by created_at
  loop
    v_target := private.as_target(v_row.target_type);
    v_label  := private.activity_label(v_target, v_row.target_id);

    perform private.log_activity(
      v_row.created_by, 'cited', v_row.created_by, v_target, v_row.target_id,
      null, v_label, v_row.created_at
    );

    if v_row.target_type = 'report' then
      select x.author_id into v_owner from public.reports x where x.id = v_row.target_id;
    else
      select x.author_id into v_owner from public.claims x where x.id = v_row.target_id;
    end if;

    perform private.log_activity(
      v_owner, 'content_cited', v_row.created_by, v_target, v_row.target_id,
      null, v_label, v_row.created_at
    );
  end loop;

  -- Moderation, last, so that a decision sits after the thing it was about. The log is
  -- complete and dated, which is why this half can be reconstructed exactly.
  for v_row in
    select action, target_type, target_id, created_at from public.moderation_actions
     order by created_at
  loop
    perform private.log_moderation(
      v_row.action, v_row.target_type, v_row.target_id, v_row.created_at
    );
  end loop;

  return (select count(*) from public.activity) - v_before;
end;
$$;

-- private.check_claim_source (was private.check_debate_source), from 20260822110200_debate_source.sql.
create or replace function private.check_claim_source()
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

-- private.log_activity, from 20260819090000_one_log_activity.sql.
create or replace function private.log_activity(
  p_subject     uuid,
  p_kind        public.activity_kind,
  p_actor       uuid,
  p_target_type public.moderation_target,
  p_target_id   uuid,
  p_comment_id  uuid default null,
  p_label       text default null,
  -- Null means "now", which is every call from a trigger. The backfill passes the date of
  -- the row it is describing.
  p_created_at  timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inbound boolean;
  v_at      timestamptz := coalesce(p_created_at, now());
begin
  -- No subject: the author was erased, or the row never had one. Nothing to deliver, and
  -- an activity row with a null subject would be undeletable by the person it is about.
  if p_subject is null or p_target_id is null then
    return;
  end if;

  -- The classification, and the reason this file has one place that knows it. No ELSE, so a
  -- kind added to the enum without a branch here fails the statement that would have
  -- produced it rather than quietly never counting as unread.
  --
  -- The CASE *statement*, not the expression: the expression form returns null when nothing
  -- matches, which would surface as a not-null violation on a column three lines further
  -- down. The statement form raises CASE_NOT_FOUND naming the value that had no branch.
  -- Same failure, one of them legible.
  case p_kind
    when 'posted_report'    then v_inbound := false;
    when 'edited_report'    then v_inbound := false;
    when 'posted_claim'     then v_inbound := false;
    when 'posted_entry'     then v_inbound := false;
    when 'commented'        then v_inbound := false;
    when 'rated_claim'      then v_inbound := false;
    when 'confirmed_report' then v_inbound := false;
    when 'flagged'          then v_inbound := false;
    when 'cited'            then v_inbound := false;

    -- The first four and claim_promoted are pre-moderation history. Nothing writes them
    -- since the gate was removed; feeds built before that still carry them, so a branch
    -- removed here would break reading rather than writing.
    when 'report_published'         then v_inbound := true;
    when 'report_changes_requested' then v_inbound := true;
    when 'entry_published'          then v_inbound := true;
    when 'entry_changes_requested'  then v_inbound := true;
    when 'claim_promoted'           then v_inbound := true;
    when 'content_hidden'           then v_inbound := true;
    when 'content_unhidden'         then v_inbound := true;
    when 'content_kept'             then v_inbound := true;
    when 'account_banned'           then v_inbound := true;
    when 'account_unbanned'         then v_inbound := true;
    when 'flag_resolved'            then v_inbound := true;
    when 'flag_dismissed'           then v_inbound := true;
    when 'content_commented'        then v_inbound := true;
    when 'comment_reply'            then v_inbound := true;
    when 'claim_rated'              then v_inbound := true;
    when 'report_confirmed'         then v_inbound := true;
    when 'content_cited'            then v_inbound := true;
  end case;

  -- Never notify somebody about their own act. The own-action half of the vocabulary is
  -- how you see your own work; an inbound row addressed to the person who caused it is a
  -- site telling you that you commented on your own report.
  if v_inbound and p_actor is not distinct from p_subject then
    return;
  end if;

  -- The dedup guard, and why the timestamp is the right key for it. A trigger fires in the
  -- same transaction as the row that fired it, so the activity row's now() and the source
  -- row's created_at default are the *same value* — not merely close. Anything the backfill
  -- would write for a row the triggers already saw therefore matches on all five columns,
  -- and the pairs that genuinely collide otherwise (two people rating one claim, several
  -- comments on one report) are separated by exactly this column.
  --
  -- That holds because no caller can set created_at: it is absent from the INSERT column
  -- grant on every source table, so the default is the only way a row gets one. If a future
  -- migration ever grants it, this guard weakens to "close enough is not equal" and starts
  -- writing duplicates — which is the reason to say so here rather than in a commit message.
  --
  -- Only when a date was passed. A trigger writing an ordinary row must never be silently
  -- swallowed because something similar happened at the same moment.
  if p_created_at is not null and exists (
    select 1
      from public.activity a
     where a.subject_id  = p_subject
       and a.kind        = p_kind
       and a.target_id   = p_target_id
       and a.comment_id is not distinct from p_comment_id
       and a.created_at  = v_at
  ) then
    return;
  end if;

  insert into public.activity (
    subject_id, kind, is_inbound, actor_id, target_type, target_id, comment_id, label,
    created_at
  )
  values (
    p_subject,
    p_kind,
    v_inbound,
    p_actor,
    p_target_type,
    p_target_id,
    p_comment_id,
    -- Trimmed to the column's limit here rather than refused by the constraint. A title is
    -- capped well below 200 characters but a claim statement is not, and a notification
    -- is not the place a length rule should first be discovered.
    nullif(left(btrim(coalesce(p_label, '')), 200), ''),
    v_at
  );
end;
$$;

-- private.log_moderation, from 20260819090000_one_log_activity.sql.
create or replace function private.log_moderation(
  p_action      public.moderation_action,
  p_target_type public.moderation_target,
  p_target_id   uuid,
  p_created_at  timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject    uuid;
  v_kind       public.activity_kind;
  v_target     public.moderation_target := p_target_type;
  v_target_id  uuid := p_target_id;
  v_comment_id uuid;
  v_label      text;
  v_parent     public.content_kind;
  v_author     uuid;
  v_kept       public.moderation_target;
  v_kept_id    uuid;
  v_kept_comment uuid;
begin
  -- An erasure records that it happened and deliberately not whose, so there is no subject
  -- to find — and the account it was about is gone by the time this runs.
  if p_target_id is null then
    return;
  end if;

  if p_target_type = 'report' then
    select x.author_id, x.title into v_subject, v_label
      from public.reports x where x.id = p_target_id;

    v_kind := case p_action
      when 'publish'         then 'report_published'
      when 'request_changes' then 'report_changes_requested'
      when 'hide'            then 'content_hidden'
      when 'unhide'          then 'content_unhidden'
    end;

  elsif p_target_type = 'claim' then
    select x.author_id, x.statement into v_subject, v_label
      from public.claims x where x.id = p_target_id;

    v_kind := case p_action
      when 'promote' then 'claim_promoted'
      when 'hide'    then 'content_hidden'
      when 'unhide'  then 'content_unhidden'
    end;

  elsif p_target_type = 'entry' then
    select x.submitter_id, x.title into v_subject, v_label
      from public.network_entries x where x.id = p_target_id;

    v_kind := case p_action
      when 'publish'         then 'entry_published'
      when 'request_changes' then 'entry_changes_requested'
      when 'hide'            then 'content_hidden'
      when 'unhide'          then 'content_unhidden'
    end;

  elsif p_target_type = 'comment' then
    -- The row moves to the thread the comment is in: target_type becomes the parent's, and
    -- the comment id rides along as the fragment. A link to a comment is a link to a page.
    select c.author_id, c.parent_type, c.parent_id
      into v_subject, v_parent, v_target_id
      from public.comments c where c.id = p_target_id;

    v_comment_id := p_target_id;
    v_target     := private.as_target(v_parent);
    v_label      := private.activity_label(v_target, v_target_id);

    v_kind := case p_action
      when 'hide'   then 'content_hidden'
      when 'unhide' then 'content_unhidden'
    end;

  elsif p_target_type = 'flag' then
    -- The flagger, not the flagged. This is the one branch whose subject is the person who
    -- asked for the decision rather than the person it was about. The target stays the flag
    -- and stays unlinked: what it named may now be hidden, and a link the flagger cannot
    -- open is worse than no link.
    select f.flagger_id,
           private.as_target(f.subject_type),
           f.subject_id,
           private.activity_label(private.as_target(f.subject_type), f.subject_id)
      into v_subject, v_kept, v_kept_id, v_label
      from public.flags f where f.id = p_target_id;

    v_kind := case p_action
      when 'resolve_flag' then 'flag_resolved'
      when 'dismiss_flag' then 'flag_dismissed'
    end;

    -- The author's half of a dismissal, written from this row rather than from a second
    -- audit row, because there was one decision and the log should say so once.
    if p_action = 'dismiss_flag' and v_kept_id is not null then
      if v_kept = 'report' then
        select x.author_id into v_author from public.reports x where x.id = v_kept_id;
      elsif v_kept = 'claim' then
        select x.author_id into v_author from public.claims x where x.id = v_kept_id;
      else
        -- A comment resolves onto its thread, so the author's row links to the page their
        -- comment is on and carries the fragment that finds it.
        v_kept_comment := v_kept_id;

        select c.author_id, c.parent_type, c.parent_id
          into v_author, v_parent, v_kept_id
          from public.comments c where c.id = v_kept_comment;

        v_kept := private.as_target(v_parent);
      end if;

      if v_author is not null and v_author is distinct from v_subject then
        perform private.log_activity(
          v_author, 'content_kept', null, v_kept, v_kept_id, v_kept_comment,
          private.activity_label(v_kept, v_kept_id), p_created_at
        );
      end if;
    end if;

  elsif p_target_type = 'account' then
    v_subject := p_target_id;

    v_kind := case p_action
      when 'ban'   then 'account_banned'
      when 'unban' then 'account_unbanned'
    end;
  end if;

  -- An action with no notification attached to it — a value added to
  -- public.moderation_action later will land here rather than raise. A missing notification
  -- is the right failure for a log that has already recorded the decision: the audit row is
  -- the record, and this table is a courtesy.
  if v_kind is null then
    return;
  end if;

  perform private.log_activity(
    v_subject, v_kind, null, v_target, v_target_id, v_comment_id, v_label, p_created_at
  );
end;
$$;

-- private.log_rating_change, from 20260821120500_rating_changes.sql.
create or replace function private.log_rating_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.rating_changes (claim_id, user_id, from_score, to_score)
  values (old.claim_id, old.user_id, old.score, new.score);

  return null;
end;
$$;

-- private.mark_claim_answered (was private.mark_debate_answered), from 20260822120000_debates_answered_at.sql.
create or replace function private.mark_claim_answered()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.claims q
     set answered_at = new.created_at
   where q.id = new.claim_id
     and q.answered_at is null
     -- Your own answer is not an answer. A proposer is required to place themselves on the scale
     -- (20260822110300), so without this every claim would be frozen at the moment it was
     -- created and no author could ever fix a typo in their own claim.
     and q.author_id is distinct from new.user_id;

  return null;
end;
$$;

-- private.protect_comment_columns, from 20260821120400_comment_edit_window.sql.
create or replace function private.protect_comment_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.comments'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for absolutely everyone. Moving a comment to another discussion, or into
  -- another position in this one, would strand the replies under it.
  new.id          := old.id;
  new.parent_type := old.parent_type;
  new.parent_id   := old.parent_id;
  new.in_reply_to := old.in_reply_to;
  new.created_at  := old.created_at;

  -- The two columns this rebuild added, frozen here as well as ungranted. A contribution's
  -- position is a fact about the moment it was written, and a caller who could move it could
  -- file their reasoning under a group they never held. `superseded_by` is written only by
  -- private.supersede_previous_contribution(), which arrives as the owner and is let through
  -- by the trusted check above.
  new.agreement_score := old.agreement_score;
  new.superseded_by   := old.superseded_by;
  new.endorsed_at     := old.endorsed_at;

  -- Hiding preserves the text and the name, which is what makes it reviewable and
  -- reversible. It is public.moderate()'s to set and nobody else's.
  new.status := old.status;

  if old.deleted_at is not null then
    -- Already gone. Nothing about a deleted comment changes again, including undeleting
    -- it: the body it had is not stored anywhere to restore.
    new.deleted_at := old.deleted_at;
    new.author_id  := old.author_id;
    new.body       := old.body;
    return new;
  end if;

  if new.deleted_at is not null then
    -- The deletion itself, and the only place these two assignments happen. The node
    -- survives so the replies under it still read; the text and the name do not.
    --
    -- Untouched by this migration. A contribution stays soft-deletable at any age, endorsed
    -- or not: its score is part of the distribution's provenance and a hard delete would take
    -- a count with it, but the words are the author's to withdraw.
    new.body      := '';
    new.author_id := null;
    return new;
  end if;

  -- An ordinary edit from here down.
  new.author_id := old.author_id;

  if new.body is distinct from old.body then
    -- Twenty-four hours, and the number is not arbitrary. Comments carry TeX, TeX is
    -- rendered at build time, and the build is nightly — so an author's first sight of
    -- their own formula rendered is up to a day after they wrote it. A window shorter than
    -- one build cycle would mean nobody could ever fix a formula that came out wrong.
    --
    -- The same 24 hours on both kinds. What differs is what closes it early.
    if old.created_at <= now() - interval '24 hours' then
      raise exception
        'The edit window on a comment is 24 hours, and this one has passed. Post a '
        'follow-up comment instead — the thread keeps both.'
        using errcode = '23514';
    end if;

    if old.parent_type = 'claim' then
      -- A claim contribution: closed by the first endorsement. Somebody has said this
      -- reasoning is theirs too, and rewriting it now would put words they never read under
      -- their agreement. There is no reply thread here in which the change could be seen —
      -- contributions on claims are flat — so the earlier text has no witness other than
      -- this rule.
      --
      -- Read off the row rather than out of public.comment_endorsements. See the note at the
      -- top of this file: this caller is not the endorser, so an `exists` here would return
      -- false however many endorsements existed and the window would be decorative.
      if old.endorsed_at is not null then
        raise exception
          'Somebody has said this contribution captures their view, so its text is fixed. '
          'Answer the claim again and write a new contribution instead — this one stays '
          'where it is, and the two are linked.'
          using errcode = '23514';
      end if;
    else
      -- A report comment: unchanged. Closed by the first reply, because people replied to
      -- the sentence in front of them and rewriting it afterwards makes their reply answer
      -- something they never read.
      if exists (select 1 from public.comments r where r.in_reply_to = old.id) then
        raise exception
          'This comment has replies, so its text is fixed. Post a follow-up instead.'
          using errcode = '23514';
      end if;
    end if;
  end if;

  return new;
end;
$$;

-- private.protect_claim_columns (was private.protect_debate_columns), from 20260822120000_debates_answered_at.sql.
create or replace function private.protect_claim_columns()
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
           where c.oid = 'public.claims'::pg_catalog.regclass),
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

  -- Written only by private.mark_claim_answered(), which arrives as the owner and is let
  -- through by the trusted check above. Frozen here as well as ungranted, so that a widened
  -- grant would still not be enough on its own to unfreeze a claim.
  new.answered_at := old.answered_at;

  -- The wording is fixed once somebody other than the author has answered. People answered the
  -- sentence in front of them, and an author who could reword it afterwards would be reassigning
  -- their agreement to a claim they never saw.
  --
  -- **Read off the row, not out of public.ratings.** See the header: a rating is readable only by
  -- its author, so this guard — which runs as the author — is told there are no other answers
  -- however many there are. Two versions of this rule were unenforceable before the column
  -- existed.
  if old.answered_at is not null then
    new.statement := old.statement;
    new.area      := old.area;
  end if;

  return new;
end;
$$;

-- private.set_comment_agreement_score, from 20260821120000_comment_agreement_score.sql.
create or replace function private.set_comment_agreement_score()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_score smallint;
begin
  -- A report comment. Overwritten to NULL rather than left alone, so that the column is
  -- right even if a caller sent something, and so the CHECK above is a statement about the
  -- table rather than a statement about what the interface happens to submit.
  if new.parent_type <> 'claim' then
    new.agreement_score := null;
    return new;
  end if;

  select r.score
    into v_score
    from public.ratings r
   where r.claim_id = new.parent_id
     and r.user_id   = new.author_id;

  -- No rating row. You cannot contribute to a claim you have not answered, and that is a
  -- feature rather than an obstacle: a contribution is a reason for a position, so a
  -- contribution from nowhere on the scale has no position to be the reason for.
  --
  -- FOUND is the right test and `v_score is null` is not. A rater who chose the off-scale
  -- option has a row whose score is NULL, and FOUND is true for them — they have answered,
  -- they may contribute, and the NULL is carried across as their position. Testing the value
  -- instead of the row would refuse exactly the people the off-scale option was added for.
  if not found then
    raise exception
      'Answer this claim before writing a contribution. A contribution is the reason for a '
      'position, so it needs a position to be the reason for — including "no opinion, or '
      'outside my expertise", which counts as answering.'
      using errcode = '23514';
  end if;

  new.agreement_score := v_score;
  return new;
end;
$$;

-- private.supersede_previous_contribution, from 20260821120300_comment_superseded_by.sql.
create or replace function private.supersede_previous_contribution()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.comments c
     set superseded_by = new.id
   where c.parent_type   = 'claim'
     and c.parent_id     = new.parent_id
     and c.author_id     = new.author_id
     -- Not the row that just arrived. It has a null superseded_by too, so without this it
     -- would supersede itself — which the CHECK above would refuse, turning an ordinary
     -- contribution into a failed insert.
     and c.id           <> new.id
     -- Only the current one. An author on their fourth contribution has three earlier ones,
     -- two of them already superseded and pointing at their own successors; rewriting those
     -- would flatten a chain of four positions into four links to the newest, and the chain
     -- is the record of how somebody arrived where they are.
     and c.superseded_by is null
     -- A soft-deleted contribution has no text left to badge and no reasoning to have moved
     -- on from. Its score stays in the distribution, which is what it is kept for.
     and c.deleted_at    is null;

  return null;
end;
$$;

-- public.answer_claim (was public.answer_debate), from 20261011110000_answer_debate.sql.
create function public.answer_claim(
  p_claim         uuid,
  -- integer, although public.ratings.score is smallint. Same reason as submit_claim's p_score:
  -- a smallint parameter makes answer_claim(..., 8, ...) fail with "function does not exist".
  p_score         integer default null,
  -- True for "no opinion, or outside my expertise". Two parameters rather than a nullable score,
  -- for the reason submit_claim's header gives: NULL is a real answer here, and "the form was
  -- not filled in" must not look like it.
  p_off_scale     boolean default false,
  -- A new contribution, or null.
  p_body          text    default null,
  -- `[{"comment_id": uuid, "kind": "captures_my_view" | "agree_position_not_reason"}, …]`
  p_endorsements  jsonb   default '[]'::jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user       uuid := (select auth.uid());
  v_score      smallint;
  v_comment_id uuid;
  v_item       jsonb;
  v_target     uuid;
  v_kind       public.endorsement_kind;
begin
  if not p_off_scale and p_score is null then
    raise exception
      'Choose a point on the scale, or say that you have no opinion — that is a real answer and '
      'it is recorded as one.'
      using errcode = '23514';
  end if;

  if p_off_scale and p_score is not null then
    raise exception
      'That is both a score and no opinion. Choose one.'
      using errcode = '23514';
  end if;

  if jsonb_typeof(coalesce(p_endorsements, '[]'::jsonb)) <> 'array' then
    raise exception 'Endorsements must be a list.' using errcode = '22023';
  end if;

  v_score := case when p_off_scale then null else p_score end;

  -- ── The position, first ─────────────────────────────────────────────────────────────
  -- First because everything after it requires it at row time. UPDATE then INSERT rather than
  -- ON CONFLICT, so this touches only the granted `score` column and only the existing
  -- policies — the same reason saveRating() in the browser did it in two requests.
  update public.ratings r
     set score = v_score
   where r.claim_id = p_claim
     and r.user_id   = v_user;

  if not found then
    insert into public.ratings (claim_id, user_id, score)
    values (p_claim, v_user, v_score);
  end if;

  -- ── A contribution of their own ───────────────────────────────────────────────────
  -- comments_set_agreement_score stamps the position just written, and
  -- comments_supersede_previous links any earlier contribution forward to this one.
  if nullif(btrim(coalesce(p_body, '')), '') is not null then
    insert into public.comments (parent_type, parent_id, author_id, in_reply_to, body)
    values ('claim', p_claim, v_user, null, btrim(p_body))
    returning id into v_comment_id;
  end if;

  -- ── Endorsements ──────────────────────────────────────────────────────────────────
  -- Each one under comment_endorsements_insert_own, which refuses the caller's own contribution,
  -- a deleted one, and one on another claim's thread — and which can see the rating above,
  -- because it is this transaction's own row. One that already exists changes kind instead.
  for v_item in select * from jsonb_array_elements(coalesce(p_endorsements, '[]'::jsonb))
  loop
    v_target := (v_item ->> 'comment_id')::uuid;
    v_kind   := (v_item ->> 'kind')::public.endorsement_kind;

    -- The endorsement policy checks that the contribution is on *a* claim the caller answered.
    -- This checks it is on *this* one, so one call cannot satisfy the rule for one claim with
    -- an endorsement on another.
    if not exists (
      select 1 from public.comments c
       where c.id          = v_target
         and c.parent_type = 'claim'
         and c.parent_id   = p_claim
    ) then
      raise exception
        'One of those contributions is not on this claim. Reload the page and try again.'
        using errcode = '23514';
    end if;

    update public.comment_endorsements e
       set kind = v_kind
     where e.comment_id = v_target
       and e.user_id    = v_user;

    if not found then
      insert into public.comment_endorsements (comment_id, user_id, kind)
      values (v_target, v_user, v_kind);
    end if;
  end loop;

  return v_comment_id;
end;
$$;

-- public.moderate, from 20260819120000_account_bans.sql.
create or replace function public.moderate(
  p_target_type public.moderation_target,
  p_target_id   uuid,
  p_action      public.moderation_action,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor         uuid := (select auth.uid());
  v_role          text;
  v_banned        boolean;
  v_reason        text := nullif(btrim(coalesce(p_reason, '')), '');
  v_author        uuid;
  v_status        text;
  v_deleted       boolean := false;
  v_kind          public.content_kind;
  v_label         text;
  v_target_role   text;
  v_target_banned boolean;
  v_user          uuid;
  v_audit         uuid;
  v_outcome       public.moderation_outcome;
  v_flag          record;
  v_flag_audit    uuid;
  v_subject       public.moderation_target;
  v_subject_id    uuid;
begin
  -- ── Who is asking ─────────────────────────────────────────────────────────────────
  -- auth.uid(), not current_user. A DEFINER function that asked current_user would see its
  -- own owner on every request; auth.uid() is a JWT claim and reads the same here as in any
  -- policy. That is what makes the authorisation below real.

  if v_actor is null then
    raise exception 'Moderation needs a signed-in account.'
      using errcode = '42501';
  end if;

  select p.role, p.is_banned
    into v_role, v_banned
    from public.profiles p
   where p.id = v_actor;

  if v_role is null or v_role not in ('moderator', 'admin') or v_banned then
    raise exception 'This account cannot take moderation actions.'
      using errcode = '42501';
  end if;

  -- ── The retired actions ───────────────────────────────────────────────────────────

  if p_action in ('publish', 'request_changes', 'promote') then
    raise exception
      'Posts are published when they are written; there is nothing to approve, send back or promote. What is left to decide is a flag: hide what it named, or leave it up. Either way, say why.'
      using errcode = '0A000';
  end if;

  -- ── The explanation ───────────────────────────────────────────────────────────────
  -- Everything but carrying out an erasure request. The same rule is a CHECK on
  -- public.moderation_actions; this copy exists so the refusal arrives as a sentence rather
  -- than as a constraint name.

  if p_action <> 'erase_account' and v_reason is null then
    raise exception
      'Every decision here needs an explanation. It is shown to whoever wrote the post and to whoever flagged it, so write it to them: one sentence saying what the problem is, or that there is not one.'
      using errcode = '23514';
  end if;

  -- ── Content: report, claim, comment, entry ───────────────────────────────────────

  if p_target_type in ('report', 'claim', 'comment', 'entry') then

    if p_target_type = 'report' then
      select x.author_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.reports x
       where x.id = p_target_id;

    elsif p_target_type = 'claim' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.claims x
       where x.id = p_target_id;

    elsif p_target_type = 'comment' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.comments x
       where x.id = p_target_id;

    else
      select x.submitter_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.network_entries x
       where x.id = p_target_id;
    end if;

    if not found then
      raise exception 'That is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_deleted then
      raise exception
        'Its author deleted that already. There is nothing left to hide; close the flag against it instead.'
        using errcode = '23514';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own post. Another moderator has to decide it — that has not changed, and it is the one shortcut that would make the record worthless.'
        using errcode = '42501';
    end if;

    if p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That is already hidden.'
          using errcode = '23514';
      end if;

      if p_target_type = 'report' then
        update public.reports set status = 'hidden' where id = p_target_id;
      elsif p_target_type = 'claim' then
        update public.claims set status = 'hidden', activated_at = null where id = p_target_id;
      elsif p_target_type = 'comment' then
        update public.comments set status = 'hidden' where id = p_target_id;
      else
        update public.network_entries set status = 'hidden' where id = p_target_id;
      end if;

      v_outcome := 'hidden';

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That is not hidden.'
          using errcode = '23514';
      end if;

      if p_target_type = 'report' then
        update public.reports set status = 'published' where id = p_target_id;
      elsif p_target_type = 'claim' then
        update public.claims set status = 'active', activated_at = now() where id = p_target_id;
      elsif p_target_type = 'comment' then
        update public.comments set status = 'published' where id = p_target_id;
      else
        update public.network_entries set status = 'published' where id = p_target_id;
      end if;

      v_outcome := 'restored';

    else
      raise exception 'That action does not apply to a post.'
        using errcode = '23514';
    end if;

    insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
    values (v_actor, p_action, p_target_type, p_target_id, v_reason)
    returning id into v_audit;

    v_label := private.activity_label(p_target_type, p_target_id);

    if v_author is not null then
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, p_target_type, p_target_id, v_label, v_outcome, v_reason, v_author, 'author'
      );
    end if;

    -- ── The flags that named it ─────────────────────────────────────────────────────
    -- Hiding answers every open flag against this row at once, each closure its own audit
    -- row and its own notice. Only the three flaggable kinds: public.flags.subject_type is
    -- public.content_kind, which has no `entry`.

    if p_action = 'hide' and p_target_type in ('report', 'claim', 'comment') then
      v_kind := case p_target_type
                  when 'report'  then 'report'::public.content_kind
                  when 'claim'   then 'claim'::public.content_kind
                  when 'comment' then 'comment'::public.content_kind
                end;

      for v_flag in
        select f.id, f.flagger_id
          from public.flags f
         where f.subject_type = v_kind
           and f.subject_id = p_target_id
           and f.status = 'open'
         order by f.created_at
      loop
        update public.flags
           set status = 'actioned', resolved_at = now(), resolved_by = v_actor
         where id = v_flag.id;

        insert into public.moderation_actions
          (actor_id, action, target_type, target_id, reason)
        values (v_actor, 'resolve_flag', 'flag', v_flag.id, v_reason)
        returning id into v_flag_audit;

        if v_flag.flagger_id is not null
           and v_flag.flagger_id is distinct from v_author
           and v_flag.flagger_id is distinct from v_actor then
          insert into public.moderation_notices (
            action_id, subject_type, subject_id, label, outcome, explanation,
            recipient_id, recipient_role
          )
          values (
            v_flag_audit, p_target_type, p_target_id, v_label, 'hidden', v_reason,
            v_flag.flagger_id, 'flagger'
          );
        end if;
      end loop;
    end if;

    return v_audit;

  -- ── Flags ─────────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'flag' then
    select f.status::text, f.flagger_id, private.as_target(f.subject_type), f.subject_id
      into v_status, v_user, v_subject, v_subject_id
      from public.flags f
     where f.id = p_target_id;

    if not found then
      raise exception 'That flag is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_status <> 'open' then
      raise exception 'That flag has already been dealt with.'
        using errcode = '23514';
    end if;

    if p_action not in ('resolve_flag', 'dismiss_flag') then
      raise exception 'That action does not apply to a flag.'
        using errcode = '23514';
    end if;

    if v_user is not distinct from v_actor then
      raise exception
        'This is your own flag. Another moderator has to answer it.'
        using errcode = '42501';
    end if;

    if v_subject = 'report' then
      select x.author_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.reports x where x.id = v_subject_id;
    elsif v_subject = 'claim' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.claims x where x.id = v_subject_id;
    else
      select x.author_id, x.status::text
        into v_author, v_status
        from public.comments x where x.id = v_subject_id;
    end if;

    if p_action = 'resolve_flag' and coalesce(v_status, 'gone') not in ('hidden', 'gone')
       and not v_deleted then
      raise exception
        'What this flag named is still on the site. Hide it — that closes this flag and every other one against it — or dismiss the flag and say why it stays.'
        using errcode = '23514';
    end if;

    update public.flags
       set status = case when p_action = 'resolve_flag'
                         then 'actioned'::public.flag_status
                         else 'dismissed'::public.flag_status
                    end,
           resolved_at = now(),
           resolved_by = v_actor
     where id = p_target_id;

    insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
    values (v_actor, p_action, 'flag', p_target_id, v_reason)
    returning id into v_audit;

    v_outcome := case when p_action = 'resolve_flag' then 'hidden' else 'kept' end;
    v_label   := private.activity_label(v_subject, v_subject_id);

    insert into public.moderation_notices (
      action_id, subject_type, subject_id, label, outcome, explanation,
      recipient_id, recipient_role
    )
    values (
      v_audit, v_subject, v_subject_id, v_label, v_outcome, v_reason, v_user, 'flagger'
    );

    if p_action = 'dismiss_flag'
       and v_author is not null
       and v_author is distinct from v_user
       and v_author is distinct from v_actor then
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, v_subject, v_subject_id, v_label, 'kept', v_reason, v_author, 'author'
      );
    end if;

    return v_audit;

  -- ── Accounts ──────────────────────────────────────────────────────────────────────
  -- A ban is the one decision here that is not about a post. It is for an account whose
  -- behaviour is the problem rather than any one thing it wrote — spam, and sustained
  -- hostility — and it is reversible, which is the whole difference between it and an
  -- erasure.
  --
  -- What it does: sets public.profiles.is_banned, which every insert policy on the site
  -- reads. Posting, commenting, rating, confirming, flagging and citing all stop. Reading
  -- does not, editing a profile does not, and asking to be erased does not — a ban is not a
  -- way to strand somebody with an account they cannot leave.
  --
  -- What it does not do: touch anything the account posted. Their reports stay in the corpus
  -- and their comments stay in their threads, because a ban is a judgement about a person's
  -- conduct and a hide is a judgement about a post, and collapsing the two would mean
  -- removing content nobody had read against the rules in docs/moderation.md.

  elsif p_target_type = 'account' then

    if p_action in ('ban', 'unban') then
      if p_target_id = v_actor then
        raise exception 'An account cannot ban itself.'
          using errcode = '42501';
      end if;

      select p.role, p.is_banned
        into v_target_role, v_target_banned
        from public.profiles p
       where p.id = p_target_id;

      if not found then
        raise exception 'There is no such account.'
          using errcode = '23503';
      end if;

      if v_target_role in ('moderator', 'admin') then
        raise exception
          'Accounts with moderation standing are not banned from this screen. That change needs direct database access, so one compromised session cannot disable the people who would notice.'
          using errcode = '42501';
      end if;

      -- Already in the state being asked for. Refused rather than repeated, because the
      -- effect is idempotent and the notification is not: a second ban would write a second
      -- audit row, a second notice, and a second feed row telling somebody their account had
      -- just been suspended when nothing had changed since the last time they were told.
      if p_action = 'ban' and v_target_banned then
        raise exception 'That account is already banned.'
          using errcode = '23514';
      end if;

      if p_action = 'unban' and not v_target_banned then
        raise exception 'That account is not banned.'
          using errcode = '23514';
      end if;

      update public.profiles
         set is_banned = (p_action = 'ban')
       where id = p_target_id;

      insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
      values (v_actor, p_action, 'account', p_target_id, v_reason)
      returning id into v_audit;

      -- Cast rather than left to the assignment. Both branches of an unadorned CASE are
      -- `unknown`, so it resolves to `text` and reaches the enum through an I/O coercion that
      -- happens to be permitted — which is a thing to rely on in a query somebody wrote once,
      -- not in the one function every moderation decision goes through.
      v_outcome := case when p_action = 'ban'
                        then 'banned'::public.moderation_outcome
                        else 'unbanned'::public.moderation_outcome
                   end;

      -- The account holder reads the same sentence the log keeps. `label` stays null: the
      -- other notices carry the heading of the post they are about, and the only heading an
      -- account has is the name of the person reading it.
      --
      -- `subject_id` is the account, and so is `recipient_id`. That is redundant here and
      -- deliberate — the row says what it is about and who it is for, in the same shape as
      -- every other notice, so the page rendering it needs no special case for whose it is.
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, 'account', p_target_id, null, v_outcome, v_reason,
        p_target_id, 'account_holder'
      );

      return v_audit;

    elsif p_action = 'erase_account' then
      -- Admins only. A ban is reversible and a content decision; this is neither.
      if v_role <> 'admin' then
        raise exception 'Erasing an account is an admin action.'
          using errcode = '42501';
      end if;

      -- p_target_id is the *request* id, not the person. The only way to reach this branch
      -- is a pending row that the account holder wrote for themselves, so an admin cannot
      -- use this to remove somebody who has not asked.
      select d.user_id
        into v_user
        from public.deletion_requests d
       where d.id = p_target_id
         and d.status = 'pending';

      if not found then
        raise exception 'That erasure request is no longer pending. Reload the page.'
          using errcode = '23503';
      end if;

      if v_user = v_actor then
        raise exception
          'Erasing your own account from here would take the record of who did it with it. Ask another admin.'
          using errcode = '42501';
      end if;

      -- The audit row goes first, and it records no target. Keeping the user id would
      -- preserve, in a table designed never to be edited, exactly the fact somebody asked us
      -- to forget — and writing it after the delete would fail, because the actor's own
      -- foreign key is fine but the row has nothing left to point at.
      insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
      values (v_actor, 'erase_account', 'account', null, v_reason)
      returning id into v_audit;

      -- The whole erasure, in one statement, because every rule about what survives is
      -- already written into the foreign keys — including public.moderation_notices, which
      -- cascades: a message addressed to somebody who no longer exists is not a record, it
      -- is an undeliverable letter.
      delete from auth.users u where u.id = v_user;

      return v_audit;

    else
      raise exception 'That action does not apply to an account.'
        using errcode = '23514';
    end if;

  else
    -- A value was added to public.moderation_target without a branch here. Refusing is the
    -- only safe answer: the alternative is an action that happens and is never logged.
    raise exception 'public.moderate() has no rule for target %', p_target_type
      using errcode = '0A000';
  end if;
end;
$$;

-- public.rating_aggregate, from 20260821130000_rating_aggregate_mean.sql.
create function public.rating_aggregate(p_claim uuid)
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
  where r.claim_id = p_claim
    -- A moderated-away claim reports nothing, even to a caller who names its id.
    and exists (
      select 1
        from public.claims q
       where q.id = p_claim
         and q.status <> 'hidden'
    );
$$;

-- public.submit_claim (was public.submit_debate), from 20260822110300_submit_debate.sql.
create or replace function public.submit_claim(
  p_statement       text,
  p_area            public.report_area,
  -- integer, although public.ratings.score is smallint. Postgres will not implicitly narrow an
  -- integer literal to smallint while resolving which function to call, so a smallint parameter
  -- makes submit_claim(..., 8, ...) fail with "function does not exist" — a message that sends
  -- you looking for a missing migration rather than a missing cast. Same reasoning, and the same
  -- comment, as submit_report's p_author_confidence. The narrowing happens on INSERT, where it
  -- is unambiguous, and the range is checked there by ratings_score_range.
  p_score           integer default null,
  -- True when the proposer chose "no opinion, or outside my expertise". See the header: this is
  -- what makes a declined answer distinguishable from an unanswered form.
  p_off_scale       boolean default false,
  p_rationale       text    default null,
  p_tag_codes       text[]  default '{}',
  p_source_url      text    default null,
  p_source_report   uuid    default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- ── The position, which is the point of this function ─────────────────────────────
  -- Checked before anything is written, so the refusal names the field rather than arriving as
  -- a constraint violation from a table the form does not mention.

  if not p_off_scale and p_score is null then
    raise exception
      'Say where you stand on your own claim. Proposing a claim means taking a position on it — '
      'and "no opinion, or outside my expertise" is one of the answers, if that is the honest one.'
      using errcode = '23514';
  end if;

  if p_off_scale and p_score is not null then
    raise exception
      'That is both a score and no opinion. Choose one.'
      using errcode = '23514';
  end if;

  -- Belt as well as braces: claims_one_source says the same thing, and this says it in a
  -- sentence about the form.
  if p_source_url is not null and p_source_report is not null then
    raise exception
      'Give one source or the other, not both — a link out, or a report from this corpus.'
      using errcode = '23514';
  end if;

  -- ── The claim ─────────────────────────────────────────────────────────────────────
  -- `author_id` is set from auth.uid() rather than taken as a parameter, so there is no
  -- argument by which this function can post under somebody else's name. `claims_insert_own`
  -- would refuse it anyway; not offering the parameter means nobody has to check.

  insert into public.claims (
    author_id, statement, rationale, area, source_url, source_report_id
  )
  values (
    (select auth.uid()),
    btrim(p_statement),
    nullif(btrim(coalesce(p_rationale, '')), ''),
    p_area,
    nullif(btrim(coalesce(p_source_url, '')), ''),
    p_source_report
  )
  returning id into v_id;

  -- ── The proposer's own position ───────────────────────────────────────────────────
  -- `p_score` when they put a number on it, NULL when they declined. Both are real rows; the
  -- difference between them is the difference the twelfth group exists to record.

  insert into public.ratings (claim_id, user_id, score)
  values (v_id, (select auth.uid()), case when p_off_scale then null else p_score end);

  -- ── Tags ──────────────────────────────────────────────────────────────────────────
  -- Matched by code rather than by id, so the client never has to know the uuids — and an
  -- unknown or retired code is **silently dropped** rather than failing a submission somebody
  -- spent ten minutes on. Retiring a tag between page load and submit is rare, and losing a tag
  -- is a far smaller harm than losing the claim. Copied deliberately from submit_report, wording
  -- included, because it is the same trade.
  --
  -- Inserted after the rating, which means `claim_tags_insert_own_unanswered` sees exactly one
  -- rating by the time it runs: the proposer's own. That policy therefore tests for a rating by
  -- somebody *else*, and 20260822110250 puts the same condition in the wording freeze. Had either
  -- tested for any rating at all, this insert would be refused on every submission — a whole
  -- feature dead on arrival, in a way no single migration reads as wrong.

  insert into public.claim_tags (claim_id, tag_id)
  select v_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;

  return v_id;
end;
$$;

-- ── 7. Grants for what section 3 dropped, and the view rebuilt ──────────────────────────
-- DROP takes a function's ACL with it and Postgres grants EXECUTE to PUBLIC on every new one, so
-- none of these lines is optional. migrate.yml asserts in production that nothing private is
-- reachable by a browser role. answer_claim is revoked from anon by name as well, because
-- 026_answer_claim.test.sql asserts that anon cannot answer and the revoke costs nothing.

revoke all on function public.rating_aggregate(uuid) from public;
grant execute on function public.rating_aggregate(uuid) to anon, authenticated;

revoke all on function public.answer_claim(uuid, integer, boolean, text, jsonb) from public, anon;
grant execute on function public.answer_claim(uuid, integer, boolean, text, jsonb) to authenticated;

-- Verbatim from 20260821130000 but for the names. security_invoker is the point of it: without
-- it a hidden claim's aggregate would be visible to anyone who cannot see the claim itself.
create view public.claim_ratings
with (security_invoker = on) as
select
  p.id as claim_id,
  a.histogram,
  a.median,
  a.mean,
  a.total_raters,
  a.opinion_count,
  a.no_opinion_count,
  a.coverage
from public.claims p
cross join lateral public.rating_aggregate(p.id) a;

grant select on public.claim_ratings to anon, authenticated;

-- ── 8. Object comments, written back ────────────────────────────────────────────────────
-- Everything section 0 captured, under its new identity and with the same substitution the
-- function bodies had. pg_identify_object's type names are COMMENT ON's keywords except for
-- columns and table constraints; its identities are already quoted and in the form COMMENT ON
-- takes, including "name on schema.table" for triggers, policies and constraints.

do $$
declare
  v_row  record;
  v_kind text;
begin
  for v_row in select * from renamed_comments loop
    v_kind := case
      when v_row.type like '% column'      then 'column'
      when v_row.type = 'table constraint' then 'constraint'
      else v_row.type
    end;
    execute format(
      'comment on %s %s is %L',
      v_kind,
      replace(replace(replace(v_row.identity,    'Debate', 'Claim'), 'debate', 'claim'), 'DEBATE', 'CLAIM'),
      replace(replace(replace(v_row.description, 'Debate', 'Claim'), 'debate', 'claim'), 'DEBATE', 'CLAIM'));
  end loop;
end $$;

drop table renamed_comments;

-- ── 9. The rename is complete, or this migration does not finish ────────────────────────
-- A rename that is 95% done is worse than one not started: the missing 5% is a function body
-- that still names public.debates and fails the first time somebody answers, months later, with
-- nothing in the diff to suggest why. 028_claims_vocabulary.test.sql asks the same questions, so
-- a later migration cannot bring the word back either.
--
-- Index key columns are excluded for the reason 20260817130000 gives: Postgres does not rewrite
-- an index's own attnames when the table column is renamed, so ratings_claim_idx keeps a key
-- column called proposition_id for ever, and nothing reads it.

do $$
declare
  v_leftovers text;
begin
  select string_agg(what, ', ' order by what) into v_leftovers from (
    select n.nspname || '.' || c.relname as what
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and c.relkind in ('r', 'v', 'm', 'p', 'i')
       and c.relname ~* 'debate'
    union all
    select n.nspname || '.' || t.typname
      from pg_type t
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname in ('public', 'private')
       and t.typname ~* 'debate'
    union all
    select n.nspname || '.' || p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and p.proname ~* 'debate'
    union all
    select 'parameter of ' || n.nspname || '.' || p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and array_to_string(p.proargnames, ',') ~* 'debate'
    union all
    select 'constraint ' || c.conname
      from pg_constraint c
      join pg_namespace n on n.oid = c.connamespace
     where n.nspname in ('public', 'private')
       and c.conname ~* 'debate'
    union all
    select 'policy ' || p.polname
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and p.polname ~* 'debate'
    union all
    select 'trigger ' || g.tgname
      from pg_trigger g
      join pg_class c on c.oid = g.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and not g.tgisinternal
       and g.tgname ~* 'debate'
    union all
    select 'column ' || c.relname || '.' || a.attname
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and c.relkind in ('r', 'v', 'm', 'p')
       and a.attnum > 0
       and not a.attisdropped
       and a.attname ~* 'debate'
    union all
    select 'enum label ' || t.typname || '.' || e.enumlabel
      from pg_enum e
      join pg_type t on t.oid = e.enumtypid
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname in ('public', 'private')
       and e.enumlabel ~* 'debate'
    union all
    select 'setting ' || s.key
      from private.settings s
     where s.key ~* 'debate'
    union all
    -- Function bodies, which do not follow a rename because they are text.
    select 'body of ' || n.nspname || '.' || p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and p.prosrc ~* 'debate'
    union all
    -- Object comments. 20260817130000 did not check these and rewrote them by hand; section 8
    -- rewrites them mechanically, so this is what proves it reached all of them.
    select 'comment on ' || o.type || ' ' || o.identity
      from pg_description d
      cross join lateral pg_identify_object(d.classoid, d.objoid, d.objsubid) o
     where (o.schema in ('public', 'private')
            -- Triggers and policies belong to a table, not a schema, and pg_identify_object reports
            -- no schema for them, nor for the two schemas themselves.
            or o.type in ('trigger', 'policy')
            or (o.type = 'schema' and o.identity in ('public', 'private')))
       and d.description ~* 'debate'
  ) leftovers;

  if v_leftovers is not null then
    raise exception 'Rename incomplete, "debate" survives in: %', v_leftovers
      using errcode = '0A000';
  end if;
end $$;
