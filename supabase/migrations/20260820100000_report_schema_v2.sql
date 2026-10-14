-- Schema version 2 of a report: the reporting standard grows the fields it was missing.
--
-- What this is for. The corpus exists so that a journal could adopt its shape as a tool
-- disclosure template, and the twelve-section form was thin in three places that anybody
-- doing secondary analysis keeps needing: **who** was working (career stage), **what the
-- prompts actually said**, and **how well it went, as numbers rather than adjectives**. It
-- also mixed two axes -- `programming` and formal verification were being written into the
-- narrative, because Area is "why you were working" and Task type is "what the tool was
-- asked to do", and neither had a home for them.
--
-- Fifteen sections now, and everything after the narrative is optional. That is the burden
-- budget doing its job: a forced number is noise in a dataset that will be read as evidence,
-- so every rating is skippable and a blank is more useful than a guess.
--
-- The five decisions in here worth reading before changing any of it
-- -----------------------------------------------------------------
--
--   1. **The example reports are deleted, not migrated.** They were written by the
--      moderators to see the pages render. Backfilling `schema_version = 1` onto them would
--      leave rows in the corpus that answer none of the new questions and that nobody can
--      complete, because the freeze rule fixes a report's text the moment somebody else
--      answers it. An empty corpus is the honest state of this project today.
--
--   2. **The enums are extended, not converted to text with a CHECK.** The
--      reporting-standard argument in 20260815100100 still holds: `alter type ... add value`
--      is a migration with a comment saying why, which is the correct amount of friction for
--      a decision that changes what every past account means. The *new* vocabularies that
--      have no enum yet -- career stage, generalisation, reference kind -- are text with a
--      CHECK, because each is a small closed list nothing joins against, and one of them is
--      read out of jsonb where an enum would buy nothing.
--
--   3. **`task_secondary` is an array of the same enum**, not a second vocabulary. A report
--      grouped under "proof drafting" and a report that also did proof drafting have to be
--      the same filter, and two spellings of one word is how that stops being true.
--
--   4. **`"references"` is quoted, because REFERENCES is a reserved word.** Every other
--      name in this schema is the JSON key and the CSV header unchanged, and an unquoted
--      identifier here would have cost a third name for one field. `select "references"` in
--      psql is a known annoyance; `supporting_material` in the database and `references` in
--      the export would be a permanent tax on every reader of the dataset.
--
--   5. **The third-party confirmation becomes conditional**, required when there is pasted
--      material and not otherwise. It was unconditional, which read as the stronger rule and
--      is the weaker one: a tick every submission needs carries no information and teaches
--      people to tick it without re-reading the excerpt. Now it is asked exactly when there
--      is something to have removed something from -- a transcript, or, new here, prompts,
--      which quote other people's material just as readily.
--
-- Nothing about moderation changes. `status` is still `published` / `hidden`, still moved
-- only by public.moderate(), and the spec's `draft` / `submitted` / `rejected` states are
-- deliberately not created: pre-moderation went on 2026-08-19, and a draft lives in
-- localStorage rather than in a table somebody has to moderate.

-- ── 1. Empty the corpus ─────────────────────────────────────────────────────────────
-- In dependency order, because the polymorphic tables have no foreign key to reports and
-- would be left pointing at nothing. Written as unconditional deletes rather than against a
-- list of ids: this migration also runs against a fresh test database, where it is a no-op,
-- and against a branch where somebody has been submitting.
--
-- Two tables are deliberately untouched:
--
--   `public.moderation_actions` is append-only and its trigger fires for the owner too, so a
--   delete here would abort the migration. That is correct rather than inconvenient -- an
--   audit row records a decision somebody took, and it stays true after the thing it was
--   about has gone. `public.moderation_notices` stays for the same reason and can: it
--   carries a snapshot `label`, so it still reads as prose without its subject.

delete from public.citations
 where (source_type = 'report' and source_id in (select id from public.reports))
    or (target_type = 'report' and target_id in (select id from public.reports))
    or  source_comment_id in (select id from public.comments where parent_type = 'report')
    or  target_comment_id in (select id from public.comments where parent_type = 'report');

delete from public.flags
 where (subject_type = 'report'  and subject_id in (select id from public.reports))
    or (subject_type = 'comment' and subject_id in
          (select id from public.comments where parent_type = 'report'));

delete from public.activity
 where (target_type = 'report' and target_id in (select id from public.reports))
    or  comment_id in (select id from public.comments where parent_type = 'report');

delete from public.comments where parent_type = 'report';

-- report_tools, report_tags and report_confirmations cascade from here.
delete from public.reports;

-- Flush the deferred events that cascade just queued, or section 8's `alter table
-- public.report_tools` fails with 55006, *cannot ALTER TABLE "report_tools" because it has
-- pending trigger events*. `report_tools_keep_at_least_one` is DEFERRABLE INITIALLY DEFERRED
-- and fires `after delete`, so every tool row the cascade removed is an event sitting in the
-- queue until COMMIT -- and Postgres will not alter a table with events pending against it.
--
-- Note which table the error names, because it is the diagnosis: `alter table public.reports`
-- a hundred lines below this succeeds, since `reports_require_a_tool` is `after insert` and a
-- delete queues nothing on the parent.
--
-- Firing them here is safe rather than merely expedient. Every queued event is a tool row
-- whose report has just gone, and `private.assert_report_has_tool()` returns null in exactly
-- that case -- "a report that no longer exists has no invariant left to violate" is the
-- comment on it in 20260817130000, which is the migration that currently defines the
-- function rather than the one that created it. The check that would fail is the one for an
-- orphan, and the cascade left none.
set constraints all immediate;

-- Put the mode back. `SET CONSTRAINTS ALL IMMEDIATE` is not scoped to the statement that
-- needed it, and a migration that leaves the transaction in immediate mode makes every
-- constraint trigger after this point fire early -- which is a different bug, in a file that
-- has already gone wrong once.
set constraints all deferred;

-- ── 2. The two axes, straightened ───────────────────────────────────────────────────
--
-- Area is *why you were working*. `outreach` and `administration` are the two kinds of
-- mathematical work the original five did not cover, and both are places where these tools
-- are used heavily and reported on never: a grant application is not research and is not
-- writing, and explaining a theorem to a school class is not teaching a course.
--
-- Task type is *what the tool was asked to do*. `comprehension` is among the commonest uses
-- there is and had nowhere to go -- "I read a paper with it" was landing in
-- `literature_search`, which is a different question. `programming` is code that is not a
-- formal proof, which `formalisation` was quietly absorbing, and that makes the
-- formalisation numbers wrong in the direction of overstating them.
--
-- `alter type ... add value` inside a transaction is fine on Postgres 12 and later provided
-- the new label is not *used* before the commit. Nothing below uses one.

-- Both positioned `before 'other'` rather than one after the other. Postgres will not let a
-- label added in this transaction be *used* before it commits, and `after 'outreach'` on the
-- second statement would be leaning on the first -- so both name only labels that were
-- already there. The resulting sort order is cosmetic in any case: display order comes from
-- AREAS in src/lib/report-schema.ts, and nothing orders by this column.
alter type public.report_area add value if not exists 'outreach'       before 'other';
alter type public.report_area add value if not exists 'administration' before 'other';

alter type public.report_task_type
  add value if not exists 'comprehension' after 'literature_search';
alter type public.report_task_type
  add value if not exists 'programming' after 'computation';

comment on type public.report_area is
  'Why the work was being done. Distinct from report_task_type, which is what the tool was '
  'asked to do: mixing the two makes both axes useless for grouping.';
comment on type public.report_task_type is
  'What the tool was asked to do. The primary axis for grouping the corpus, and also the '
  'vocabulary of reports.task_secondary.';

-- ── 3. The new columns ──────────────────────────────────────────────────────────────

alter table public.reports
  -- Bumped whenever a field or a vocabulary changes, so an analysis five years from now can
  -- tell a row that answered a question from a row that was never asked it. There is no
  -- INSERT or UPDATE grant for it in either direction and the guard trigger freezes it: it
  -- is the schema's statement about the row, not the author's.
  add column schema_version smallint not null default 2,

  -- Section 2. Required exactly when the area is `other`, which is the only way "other"
  -- means anything: an unqualified `other` is a row that has opted out of the axis.
  add column area_other text,

  -- Section 3. Anything else the tool was asked to do in the same session. The primary is
  -- what the corpus groups by; this is what stops a session that drafted *and* checked a
  -- proof from having to pick one and lose the other.
  add column task_secondary public.report_task_type[] not null default '{}',

  -- Section 5. Coarse on purpose, and optional on purpose. Reports are permanent and under
  -- CC BY: career stage plus subject area plus a date is already close to identifying in a
  -- small field, which is why institution, country and year of birth are not here and must
  -- not be added. There is no `prefer_not_to_say` value -- the column is nullable, so a null
  -- already says that, and offering both makes the blank state ambiguous.
  add column career_stage text,

  -- Section 10. The part of the record with instructional value: a prompt is short,
  -- reusable, and is what a reader copies. Kept apart from the transcript because a
  -- transcript is evidence nobody reads except to check a claim, and one box for both buries
  -- the prompt where it can be neither indexed nor shown in a listing.
  add column prompts text,

  -- Section 13. Links only, and the quoting is explained in the header. jsonb rather than a
  -- child table: unlike a tool, a reference has no date to go stale, nothing joins to it,
  -- and nothing filters on more than "is there one of kind X".
  add column "references" jsonb not null default '[]'::jsonb,

  -- Section 14. Five scales, two of them shown conditionally, all null when unanswered.
  -- Never 0 for "not asked": a hidden scale submitting 0 would write "no help at all" into
  -- the corpus for every teaching-prep session that was never asked about novelty.
  add column rating_helpfulness           smallint,
  add column rating_time_saved            smallint,
  add column rating_trust_before_checking smallint,
  add column rating_verification_effort   smallint,
  add column rating_novelty               smallint,
  add column rating_understanding_gained  smallint,

  -- The one fact a 0-to-10 scale cannot hold. Without it, "the tool wasted my afternoon" and
  -- "the tool was mildly disappointing" both score 0 on time saved, and the first is one of
  -- the most useful things this corpus can record.
  add column cost_more_time_than_saved boolean not null default false,

  -- Not a scale, deliberately. How far the author thinks this carries is a guess, and three
  -- named answers say so where an 11-point number would pretend to a precision nobody has.
  add column generalises text;

-- Two derived booleans, and they exist for one caller: the freshness overlay in
-- src/lib/fresh.ts, which has to decide whether a report posted since the last export matches
-- the "includes the prompts" and "includes a transcript" filters.
--
-- Without them that decision costs the text. A transcript excerpt is capped at twenty thousand
-- characters and the overlay fetches two dozen rows, so answering a yes-or-no question would
-- mean pulling half a megabyte onto a listing page -- on the one query in this project that is
-- allowed to touch the database from a reading page, and only because it is small. The
-- alternative is a fresh card that quietly fails a filter it should match, which is precisely
-- the class of bug the overlay's rules exist to prevent.
--
-- STORED because Postgres has no other kind, and generated rather than trigger-maintained
-- because a copy kept in step by a trigger is a copy that can be out of step. Nothing may
-- write these: a generated column has no INSERT or UPDATE grant to give, which is also why
-- the guard trigger does not name them.
--
-- **A separate statement, on purpose.** `has_prompts` reads `prompts`, which the ALTER TABLE
-- above adds, and a generation expression that resolves a column added by its own statement is
-- asking Postgres a question it is under no obligation to answer. Two statements cost nothing
-- and remove the question.

alter table public.reports
  add column has_prompts boolean
    generated always as (prompts is not null) stored,
  add column has_transcript boolean
    generated always as (transcript_excerpt is not null) stored;

-- ── 4. What the new columns will and will not hold ──────────────────────────────────

alter table public.reports
  add constraint reports_schema_version_known
    check (schema_version >= 2),

  -- Both directions. An `area_other` on a report whose area is `research` is a field that
  -- will never be displayed and will be read as data by somebody.
  add constraint reports_area_other_iff_other
    check (
      case
        when area = 'other' then length(btrim(coalesce(area_other, ''))) between 1 and 80
        else area_other is null
      end
    ),

  -- Three, matching the form. Deduplication and stripping the primary are done by the
  -- normalising trigger below rather than refused here: a duplicated secondary task is a
  -- slip with one obvious right answer, and a submission somebody spent ten minutes on
  -- should not fail on one.
  add constraint reports_task_secondary_max
    check (cardinality(task_secondary) <= 3),

  add constraint reports_career_stage_known
    check (
      career_stage is null
      or career_stage in ('undergraduate', 'masters', 'doctoral', 'postdoctoral', 'faculty',
                          'researcher_outside_academia', 'teacher', 'independent', 'other')
    ),

  add constraint reports_prompts_length
    check (prompts is null or length(prompts) <= 4000),

  -- Shape and count only. The per-element rules need a message written for a person, so they
  -- are in private.check_report_references() below.
  add constraint reports_references_shape
    check (jsonb_typeof("references") = 'array' and jsonb_array_length("references") <= 8),

  add constraint reports_rating_helpfulness_range
    check (rating_helpfulness is null or rating_helpfulness between 0 and 10),
  add constraint reports_rating_time_saved_range
    check (rating_time_saved is null or rating_time_saved between 0 and 10),
  add constraint reports_rating_trust_range
    check (rating_trust_before_checking is null
           or rating_trust_before_checking between 0 and 10),
  add constraint reports_rating_verification_effort_range
    check (rating_verification_effort is null or rating_verification_effort between 0 and 10),
  add constraint reports_rating_novelty_range
    check (rating_novelty is null or rating_novelty between 0 and 10),
  add constraint reports_rating_understanding_range
    check (rating_understanding_gained is null
           or rating_understanding_gained between 0 and 10),

  add constraint reports_generalises_known
    check (generalises is null
           or generalises in ('task_specific', 'similar_tasks', 'broadly'));

-- ── 5. The third-party confirmation becomes conditional ─────────────────────────────
-- See decision 5 in the header. The rule is now "affirm it when you have pasted something",
-- and `prompts` counts as having pasted something: a prompt quoting a colleague's
-- unpublished conjecture is the same disclosure as a transcript quoting it.
--
-- Note which direction this moves in. Before, a report with a transcript could not exist
-- without the tick and neither could a report with nothing pasted at all. The first is
-- unchanged; the second is now allowed, and the tick means something when it is there.

alter table public.reports
  drop constraint reports_third_party_material_confirmed;

alter table public.reports
  add constraint reports_third_party_material_confirmed
    check (
      third_party_material_confirmed
      or (transcript_excerpt is null and prompts is null)
    );

comment on column public.reports.third_party_material_confirmed is
  'The author''s affirmation that third-party unpublished material was removed from what '
  'they pasted. Required when there is a transcript excerpt or a prompt, and meaningless '
  'when there is neither -- which is why it is no longer required unconditionally.';

comment on column public.reports.schema_version is
  'Which version of the reporting standard this row was written against. Bumped by a '
  'migration when a field or a vocabulary changes; never written by a caller.';
comment on column public.reports.task_secondary is
  'Anything else the tool was asked to do in the same session. Never contains task_type and '
  'never contains a duplicate: private.normalise_report_tasks() sees to both.';
comment on column public.reports.career_stage is
  'Coarse and optional. Institution, country and date of birth are deliberately not '
  'collected: a report is permanent and under CC BY, and this field plus a subject area is '
  'already close to identifying in a small field.';
comment on column public.reports.prompts is
  'The prompts, verbatim, including the ones that had to be rewritten. Rendered escaped and '
  'monospace, never as Markdown or TeX: the point of the field is that it is not prose.';
comment on column public.reports."references" is
  'Supporting links: [{"kind": "...", "url": "https://...", "label": "..."}]. Quoted because '
  'REFERENCES is reserved; the name is kept so the JSON key and the CSV header do not need a '
  'third spelling. Validated by private.check_report_references().';
comment on column public.reports.cost_more_time_than_saved is
  'The fact a 0-10 scale cannot express. Without it, a wasted afternoon and a mild '
  'disappointment both score 0 on rating_time_saved.';
comment on column public.reports.rating_novelty is
  'Null when the question was not asked, which is most of the corpus: it is shown only when '
  'the area or a task type makes novelty a meaningful question. Never 0 for "not asked".';
comment on column public.reports.rating_understanding_gained is
  'Null when the question was not asked. See rating_novelty.';
comment on column public.reports.has_prompts is
  'Generated. Exists so the freshness overlay can answer "includes the prompts" without '
  'fetching the prompts. Not exported: the export carries the text itself.';
comment on column public.reports.has_transcript is
  'Generated. See has_prompts.';

-- ── 6. Normalising the secondary tasks ──────────────────────────────────────────────
-- BEFORE, so it runs ahead of reports_task_secondary_max: a form that sent four values one
-- of which was the primary has sent three, and should be told so by nothing.
--
-- SECURITY INVOKER, and it asks nothing about the caller, so the DEFINER trap does not apply
-- in either direction. It is INVOKER because it has no reason not to be.

create function private.normalise_report_tasks()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.task_secondary is null then
    new.task_secondary := '{}'::public.report_task_type[];
    return new;
  end if;

  -- Distinct, primary removed, and in the vocabulary's own order rather than the order the
  -- checkboxes happened to be ticked in -- so two identical answers are one value in the
  -- export rather than two orderings of it.
  select coalesce(array_agg(distinct t order by t), '{}')
    into new.task_secondary
    from unnest(new.task_secondary) as t
   where t <> new.task_type;

  return new;
end;
$$;

comment on function private.normalise_report_tasks() is
  'Deduplicates reports.task_secondary, removes the primary task from it, and sorts it. '
  'BEFORE, so the cardinality constraint sees the normalised array.';

revoke all on function private.normalise_report_tasks() from public;

create trigger reports_normalise_tasks
  before insert or update on public.reports
  for each row
  execute function private.normalise_report_tasks();

-- ── 7. The reference links ──────────────────────────────────────────────────────────
-- A trigger rather than a CHECK, because every rule here has a sentence attached and the
-- caller who trips one is a person who has just pasted a link, not a script.
--
-- What it refuses, and why each one:
--
--   `https` only. `http` is a link this audience will not click, `file:` and `localhost` are
--   somebody's own machine, and a private range is somebody's intranet. All of them are
--   links that work for exactly one reader.
--
--   Nothing about whether the link *resolves*. That is what scripts/link-check.mjs is for,
--   monthly, and a constraint guessing at it would refuse working URLs with brackets and
--   commas in them.
--
-- The warning about Drive, Dropbox, Overleaf and SharePoint is the form's job and stays
-- there: "most links to these are not readable signed out" is advice, and a database that
-- refused them would refuse the ones that are.

create function private.check_report_references()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item jsonb;
  v_url  text;
  v_kind text;
begin
  -- Checked here as well as by reports_references_shape, because jsonb_array_elements on an
  -- object raises 22023 -- "cannot extract elements from an object" -- and this trigger runs
  -- before the constraint that would have said something a person can act on.
  if jsonb_typeof(new."references") <> 'array' then
    raise exception 'The supporting links have to be a list, even when there is one of them.'
      using errcode = '23514';
  end if;

  for v_item in select * from jsonb_array_elements(new."references")
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'A supporting link has to be a kind and a URL, not %.',
        jsonb_typeof(v_item)
        using errcode = '23514';
    end if;

    v_kind := v_item ->> 'kind';
    v_url  := btrim(coalesce(v_item ->> 'url', ''));

    if v_kind is null
       or v_kind not in ('paper', 'code', 'notebook', 'formalisation', 'overleaf',
                         'dataset', 'figure', 'slides', 'other') then
      raise exception 'Choose what kind of thing each supporting link is.'
        using errcode = '23514';
    end if;

    if v_url = '' then
      raise exception 'Give a URL for each supporting link, or remove the row.'
        using errcode = '23514';
    end if;

    if length(v_url) > 500 then
      raise exception
        'That supporting link is longer than 500 characters. Check it is the link you meant.'
        using errcode = '23514';
    end if;

    if v_url !~ '^https://[^[:space:]]+$' then
      raise exception
        'Supporting links have to start with https://. A link nobody can open from outside is not a reference.'
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

    if length(btrim(coalesce(v_item ->> 'label', ''))) > 80 then
      raise exception 'Shorten that link''s label to 80 characters or fewer.'
        using errcode = '23514';
    end if;
  end loop;

  return new;
end;
$$;

comment on function private.check_report_references() is
  'Validates each element of reports."references" and raises a finished sentence. https '
  'only, and no private addresses. Says nothing about whether a link resolves -- that is '
  'scripts/link-check.mjs, monthly.';

revoke all on function private.check_report_references() from public;

create trigger reports_check_references
  before insert or update on public.reports
  for each row
  when (new."references" <> '[]'::jsonb)
  execute function private.check_report_references();

-- ── 8. What a tool row says it did ──────────────────────────────────────────────────
-- `role` is what turns two tool rows into an account: a model that drafted the sketch and a
-- proof assistant that checked it is a different session from two models tried in turn, and
-- until now the difference lived only in the prose.
--
-- The caps come down to the form's -- 80 and 40 rather than 120 and 60. Nothing is refused
-- that was not already implausible: no tool has an eighty-character name, and a version
-- longer than forty characters is a sentence in the wrong field.

alter table public.report_tools
  add column role text;

alter table public.report_tools
  drop constraint report_tools_name_length,
  drop constraint report_tools_version_length;

alter table public.report_tools
  add constraint report_tools_name_length
    check (length(btrim(tool_name)) between 1 and 80),
  add constraint report_tools_version_length
    check (length(btrim(tool_version)) between 1 and 40),
  add constraint report_tools_role_length
    check (role is null or length(btrim(role)) between 1 and 60);

comment on column public.report_tools.role is
  'What this tool did, in a few words: "drafted the sketch", "checked the proof". Optional, '
  'and part of the uniqueness key -- one tool can appear twice in one day in two roles.';

-- The same tool at the same version on the same day in the same role is one use. `role` had
-- to join the key: without it, "Claude drafted the sketch" and "Claude checked the proof",
-- same version, same afternoon, is a unique violation on the second row -- which is exactly
-- the account the column was added to make possible.
--
-- A functional index over coalesce(role, '') rather than a constraint, so that two rows with
-- no role are still the duplicate they were before the column existed. UNIQUE NULLS NOT
-- DISTINCT would say the same thing on this Postgres; this says it on any.

alter table public.report_tools drop constraint report_tools_distinct;

-- The expression is parenthesised. Postgres lets an index expression go bare only when it
-- "looks like a function call", and COALESCE is a SQL construct rather than a function, so
-- the bare form is a syntax error on the last column of the list.
create unique index report_tools_distinct_idx
  on public.report_tools (report_id, tool_name, tool_version, used_on, (coalesce(role, '')));

comment on index public.report_tools_distinct_idx is
  'Replaces the report_tools_distinct constraint. coalesce so that two role-less rows for '
  'the same tool on the same day are still duplicates.';

-- Re-granted in full rather than added to, because a column grant list is the kind of thing
-- that is only ever read as a whole. `id`, `report_id` and `created_at` stay absent from
-- UPDATE: a tool row is replaced, not re-parented.
grant insert (report_id, tool_name, tool_version, used_on, role)
  on public.report_tools to authenticated;
grant update (tool_name, tool_version, used_on, role)
  on public.report_tools to authenticated;

-- ── 9. Indexes ──────────────────────────────────────────────────────────────────────
-- One. `area`, `task_type`, `created_at` and the published-and-not-deleted partial are all
-- indexed already, and there is deliberately nothing here for career stage, generalisation
-- or the ratings: every listing filter on this site runs in the browser over cards a build
-- already rendered, so an index for one of those would serve no query that exists.
--
-- This one serves a query that does exist. "Reports that also did proof drafting" is a
-- filter, and a GIN index over an enum array is what answers it without a sequential scan
-- once the corpus is large enough for that to matter.

create index reports_task_secondary_idx
  on public.reports using gin (task_secondary);

-- ── 10. The guard, reissued ─────────────────────────────────────────────────────────
-- Reissued in full rather than patched, because a guard read in two halves is a guard read
-- wrong. The only changes from 20260819100000 are `schema_version` joining the always-
-- immutable set and the eleven new content columns joining the freeze list -- which is the
-- point of reissuing it: a new column that the freeze list does not name is a column an
-- author can still rewrite after somebody has confirmed the report, and nothing warns you.

create or replace function private.protect_report_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  new.updated_at := now();

  -- SECURITY INVOKER, so current_user is whoever is actually running the statement:
  -- `authenticated` for a browser, the table's owner when public.moderate() performs the
  -- update, and the owner again when private.mark_report_answered() stamps the date. As
  -- DEFINER this would always be the owner and the guard would never fire -- which is the
  -- trap recorded in CLAUDE.md and the reason this line reads the way it does.
  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.reports'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for everyone. Reassigning an author would move a contribution onto somebody
  -- else's name, which is the one thing a corpus under CC BY must never do.
  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  -- Which version of the reporting standard this row was written against is a fact about
  -- the schema, not an answer. There is no column grant for it either; this is the second
  -- lock, for the day somebody widens the first.
  new.schema_version := old.schema_version;

  -- Status is nobody's to set from a browser. There is no moderator policy on this table and
  -- there will not be one again: public.moderate() is the only way into hidden or out of it,
  -- which is what keeps every such move in the log.
  new.status := old.status;

  -- Nor is the date somebody else's answer put there.
  new.answered_at := old.answered_at;

  -- Restoring a deleted report is a moderation action, not an authoring one. Without this,
  -- "delete" would be a toggle and a soft-deleted row could be brought back after the
  -- discussion around it had moved on.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- **The text is fixed once somebody else has answered, and unfixed again while it is
  -- hidden.** An account that can be rewritten after people have confirmed it still works is
  -- not a record of anything -- the confirmations would attest to a version nobody can read.
  -- Until anybody has answered there is nothing pointing at the old text, so a correction
  -- misleads nobody; and hidden content is off the site with its author holding a written
  -- reason, which is exactly when rewriting it is the point.
  --
  -- The same condition is in reports_update_own_editable, which is what actually refuses the
  -- statement. This is the second lock, and it is the one that decides *columns* -- an author
  -- whose report is still editable may change the text and still may not touch `status`.
  if old.status <> 'hidden' and old.answered_at is not null then
    new.title                          := old.title;
    new.area                           := old.area;
    new.area_other                     := old.area_other;
    new.task_type                      := old.task_type;
    new.task_secondary                 := old.task_secondary;
    new.career_stage                   := old.career_stage;
    new.aim                            := old.aim;
    new.method                         := old.method;
    new.outcome                        := old.outcome;
    new.outcome_notes                  := old.outcome_notes;
    new.verification                   := old.verification;
    new.prompts                        := old.prompts;
    new.transcript_excerpt             := old.transcript_excerpt;
    new.transcript_url                 := old.transcript_url;
    new."references"                   := old."references";
    new.caveats                        := old.caveats;
    new.third_party_material_confirmed := old.third_party_material_confirmed;
    new.time_spent_minutes             := old.time_spent_minutes;
    new.was_published                  := old.was_published;
    new.was_disclosed                  := old.was_disclosed;
    new.author_confidence              := old.author_confidence;
    new.rating_helpfulness             := old.rating_helpfulness;
    new.rating_time_saved              := old.rating_time_saved;
    new.rating_trust_before_checking   := old.rating_trust_before_checking;
    new.rating_verification_effort     := old.rating_verification_effort;
    new.rating_novelty                 := old.rating_novelty;
    new.rating_understanding_gained    := old.rating_understanding_gained;
    new.cost_more_time_than_saved      := old.cost_more_time_than_saved;
    new.generalises                    := old.generalises;
  end if;

  return new;
end;
$$;

comment on function private.protect_report_columns() is
  'Reverts writes to columns the caller does not own. Text is editable while the report is '
  'hidden, and until answered_at is set. Deliberately SECURITY INVOKER: as DEFINER, '
  'current_user would always be the owner and the guard would never fire.';

-- ── 11. Grants ──────────────────────────────────────────────────────────────────────
-- Re-granted in full for the same reason the guard is reissued in full: a column grant list
-- that has been appended to three times is a list nobody reads. Absent from both, on
-- purpose: `id`, `status`, `schema_version`, `answered_at`, `created_at`, `updated_at`. A
-- caller cannot name them, so the attempt fails with 42501 before any policy is consulted.
--
-- `status` is in the UPDATE list and nowhere else, and that is not a slip: moderators reach
-- PostgREST as the same `authenticated` role as everybody else, so a column grant cannot
-- distinguish them. The absent moderator policy and the guard above are what restrict it.

grant insert (
  author_id, title, area, area_other, task_type, task_secondary, career_stage,
  aim, method, outcome, outcome_notes, verification,
  prompts, transcript_excerpt, transcript_url, "references", caveats,
  third_party_material_confirmed, time_spent_minutes, was_published, was_disclosed,
  author_confidence, rating_helpfulness, rating_time_saved, rating_trust_before_checking,
  rating_verification_effort, rating_novelty, rating_understanding_gained,
  cost_more_time_than_saved, generalises
) on public.reports to authenticated;

grant update (
  status, title, area, area_other, task_type, task_secondary, career_stage,
  aim, method, outcome, outcome_notes, verification,
  prompts, transcript_excerpt, transcript_url, "references", caveats,
  third_party_material_confirmed, time_spent_minutes, was_published, was_disclosed,
  author_confidence, rating_helpfulness, rating_time_saved, rating_trust_before_checking,
  rating_verification_effort, rating_novelty, rating_understanding_gained,
  cost_more_time_than_saved, generalises,
  deleted_at, deleted_by
) on public.reports to authenticated;

-- ── 12. submit_report and resubmit_report ───────────────────────────────────────────
--
-- **Dropped and recreated, not replaced.** `create or replace function` is not idempotent
-- across a signature change: adding a parameter creates a *second* function, the old one
-- stays, and every call that fits both becomes "function ... is not unique". That is not
-- hypothetical here -- it is exactly how 20260819090000 came to exist, after two
-- private.log_activity()s stopped every content write on the site while reading looked
-- perfectly healthy because reading is static.
--
-- Every new parameter is appended after `p_tag_codes` and defaulted, so a positional call
-- written against the old signature still resolves. The ratings are `integer` rather than
-- `smallint` for the reason the original migration gives: Postgres will not implicitly
-- narrow an integer literal to smallint while resolving which function to call, so a
-- smallint parameter turns `submit_report(..., 8, ...)` into "function does not exist" --
-- a message that sends you looking for a missing migration rather than a missing cast.
--
-- `p_task_secondary` is `text[]` and cast inside, for the same reason: `array['exposition']`
-- is text[], and a `report_task_type[]` parameter would make every positional call fail
-- resolution rather than fail a cast.

drop function public.submit_report;
drop function public.resubmit_report;

create function public.submit_report(
  p_title                          text,
  p_area                           public.report_area,
  p_task_type                      public.report_task_type,
  -- [{"name": "GPT-5", "version": "2026-05", "used_on": "2026-08-01", "role": "drafted"}, ...]
  p_tools                          jsonb,
  p_aim                            text,
  p_method                         text,
  p_outcome                        public.report_outcome,
  p_outcome_notes                  text,
  p_verification                   text,
  p_third_party_material_confirmed boolean,
  p_transcript_excerpt             text     default null,
  p_transcript_url                 text     default null,
  p_caveats                        text     default null,
  p_time_spent_minutes             integer  default null,
  p_was_published                  boolean  default null,
  p_was_disclosed                  boolean  default null,
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}',
  -- Everything below arrived with schema version 2.
  p_area_other                     text     default null,
  p_task_secondary                 text[]   default '{}',
  p_career_stage                   text     default null,
  p_prompts                        text     default null,
  -- [{"kind": "paper", "url": "https://doi.org/...", "label": "The preprint"}, ...]
  p_references                     jsonb    default '[]'::jsonb,
  p_rating_helpfulness             integer  default null,
  p_rating_time_saved              integer  default null,
  p_cost_more_time_than_saved      boolean  default false,
  p_rating_trust_before_checking   integer  default null,
  p_rating_verification_effort     integer  default null,
  p_rating_novelty                 integer  default null,
  p_rating_understanding_gained    integer  default null,
  p_generalises                    text     default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id   uuid;
  v_tool jsonb;
begin
  -- Checked here as well as by the deferred trigger, purely so the message is a sentence
  -- about the form rather than one about a constraint. The trigger is still the truth; a
  -- caller that skipped this function would meet it instead.
  if p_tools is null
     or jsonb_typeof(p_tools) <> 'array'
     or jsonb_array_length(p_tools) = 0 then
    raise exception 'Record at least one tool, with its version and the date you used it.'
      using errcode = '23514';
  end if;

  -- Six, down from twenty. Six rows is already an unusually careful account of one session,
  -- and past that the rows stop describing a session and start describing a year.
  if jsonb_array_length(p_tools) > 6 then
    raise exception 'That is more tools than one account of a session can usefully describe. Six is the most, and a separate report is the honest way to record a second session.'
      using errcode = '23514';
  end if;

  -- jsonb_typeof first, because jsonb_array_length on an object raises 22023 rather than
  -- anything a caller can read. The trigger says the same thing; this says it earlier.
  if p_references is not null
     and jsonb_typeof(p_references) = 'array'
     and jsonb_array_length(p_references) > 8 then
    raise exception 'Eight supporting links is the most. Pick the ones a reader would actually follow.'
      using errcode = '23514';
  end if;

  insert into public.reports (
    author_id, title, area, area_other, task_type, task_secondary, career_stage,
    aim, method, outcome, outcome_notes, verification,
    prompts, transcript_excerpt, transcript_url, "references", caveats,
    third_party_material_confirmed, time_spent_minutes, was_published, was_disclosed,
    author_confidence, rating_helpfulness, rating_time_saved, rating_trust_before_checking,
    rating_verification_effort, rating_novelty, rating_understanding_gained,
    cost_more_time_than_saved, generalises
  )
  values (
    -- Not a parameter, and never will be.
    (select auth.uid()),
    btrim(p_title), p_area, nullif(btrim(coalesce(p_area_other, '')), ''),
    p_task_type,
    coalesce(p_task_secondary, '{}')::public.report_task_type[],
    nullif(btrim(coalesce(p_career_stage, '')), ''),
    btrim(p_aim), btrim(p_method), p_outcome, btrim(p_outcome_notes), btrim(p_verification),
    nullif(btrim(coalesce(p_prompts, '')), ''),
    nullif(btrim(coalesce(p_transcript_excerpt, '')), ''),
    nullif(btrim(coalesce(p_transcript_url, '')), ''),
    coalesce(p_references, '[]'::jsonb),
    nullif(btrim(coalesce(p_caveats, '')), ''),
    p_third_party_material_confirmed, p_time_spent_minutes, p_was_published,
    p_was_disclosed, p_author_confidence,
    p_rating_helpfulness, p_rating_time_saved, p_rating_trust_before_checking,
    p_rating_verification_effort, p_rating_novelty, p_rating_understanding_gained,
    coalesce(p_cost_more_time_than_saved, false),
    nullif(btrim(coalesce(p_generalises, '')), '')
  )
  returning id into v_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.report_tools (report_id, tool_name, tool_version, used_on, role)
    values (
      v_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date,
      nullif(btrim(coalesce(v_tool ->> 'role', '')), '')
    );
  end loop;

  -- Tags are matched by code rather than by id, so the client never has to know the uuids,
  -- and an unknown or retired code is silently dropped instead of failing a submission
  -- somebody spent ten minutes on. Retiring a tag between page load and submit is rare, and
  -- losing a tag is a far smaller harm than losing the account of the work.
  insert into public.report_tags (report_id, tag_id)
  select v_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;

  return v_id;
end;
$$;

create function public.resubmit_report(
  p_report_id                      uuid,
  p_title                          text,
  p_area                           public.report_area,
  p_task_type                      public.report_task_type,
  p_tools                          jsonb,
  p_aim                            text,
  p_method                         text,
  p_outcome                        public.report_outcome,
  p_outcome_notes                  text,
  p_verification                   text,
  p_third_party_material_confirmed boolean,
  p_transcript_excerpt             text     default null,
  p_transcript_url                 text     default null,
  p_caveats                        text     default null,
  p_time_spent_minutes             integer  default null,
  p_was_published                  boolean  default null,
  p_was_disclosed                  boolean  default null,
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}',
  p_area_other                     text     default null,
  p_task_secondary                 text[]   default '{}',
  p_career_stage                   text     default null,
  p_prompts                        text     default null,
  p_references                     jsonb    default '[]'::jsonb,
  p_rating_helpfulness             integer  default null,
  p_rating_time_saved              integer  default null,
  p_cost_more_time_than_saved      boolean  default false,
  p_rating_trust_before_checking   integer  default null,
  p_rating_verification_effort     integer  default null,
  p_rating_novelty                 integer  default null,
  p_rating_understanding_gained    integer  default null,
  p_generalises                    text     default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_updated integer;
  v_tool    jsonb;
begin
  if p_tools is null
     or jsonb_typeof(p_tools) <> 'array'
     or jsonb_array_length(p_tools) = 0 then
    raise exception 'Record at least one tool, with its version and the date you used it.'
      using errcode = '23514';
  end if;

  if jsonb_array_length(p_tools) > 6 then
    raise exception 'That is more tools than one account of a session can usefully describe. Six is the most, and a separate report is the honest way to record a second session.'
      using errcode = '23514';
  end if;

  -- jsonb_typeof first, because jsonb_array_length on an object raises 22023 rather than
  -- anything a caller can read. The trigger says the same thing; this says it earlier.
  if p_references is not null
     and jsonb_typeof(p_references) = 'array'
     and jsonb_array_length(p_references) > 8 then
    raise exception 'Eight supporting links is the most. Pick the ones a reader would actually follow.'
      using errcode = '23514';
  end if;

  -- The update matches zero rows if the report does not exist, is not the caller's, or is no
  -- longer editable -- reports_update_own_editable refuses it. Check the count so the caller
  -- gets a clear error rather than silent success followed by a puzzling state.
  update public.reports set
    title                          = btrim(p_title),
    area                           = p_area,
    area_other                     = nullif(btrim(coalesce(p_area_other, '')), ''),
    task_type                      = p_task_type,
    task_secondary                 = coalesce(p_task_secondary, '{}')::public.report_task_type[],
    career_stage                   = nullif(btrim(coalesce(p_career_stage, '')), ''),
    aim                            = btrim(p_aim),
    method                         = btrim(p_method),
    outcome                        = p_outcome,
    outcome_notes                  = btrim(p_outcome_notes),
    verification                   = btrim(p_verification),
    prompts                        = nullif(btrim(coalesce(p_prompts, '')), ''),
    transcript_excerpt             = nullif(btrim(coalesce(p_transcript_excerpt, '')), ''),
    transcript_url                 = nullif(btrim(coalesce(p_transcript_url, '')), ''),
    "references"                   = coalesce(p_references, '[]'::jsonb),
    caveats                        = nullif(btrim(coalesce(p_caveats, '')), ''),
    third_party_material_confirmed = p_third_party_material_confirmed,
    time_spent_minutes             = p_time_spent_minutes,
    was_published                  = p_was_published,
    was_disclosed                  = p_was_disclosed,
    author_confidence              = p_author_confidence,
    rating_helpfulness             = p_rating_helpfulness,
    rating_time_saved              = p_rating_time_saved,
    rating_trust_before_checking   = p_rating_trust_before_checking,
    rating_verification_effort     = p_rating_verification_effort,
    rating_novelty                 = p_rating_novelty,
    rating_understanding_gained    = p_rating_understanding_gained,
    cost_more_time_than_saved      = coalesce(p_cost_more_time_than_saved, false),
    generalises                    = nullif(btrim(coalesce(p_generalises, '')), '')
  where id = p_report_id;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception
      'This report was not found, or it can no longer be edited. A report is editable while it is hidden, and until somebody else has confirmed or commented on it — after that the text is fixed, because their answer attests to a version.'
      using errcode = 'P0002';
  end if;

  -- Replace tools atomically. The deferred constraint sees the final state -- the new rows
  -- inserted below -- rather than the empty intermediate.
  delete from public.report_tools where report_id = p_report_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.report_tools (report_id, tool_name, tool_version, used_on, role)
    values (
      p_report_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date,
      nullif(btrim(coalesce(v_tool ->> 'role', '')), '')
    );
  end loop;

  -- Replace tags. Unknown or retired codes are silently dropped, as in submit_report.
  delete from public.report_tags where report_id = p_report_id;

  insert into public.report_tags (report_id, tag_id)
  select p_report_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;
end;
$$;

comment on function public.submit_report is
  'Inserts a report, its tools and its tags in one transaction, as the caller. SECURITY '
  'INVOKER: every policy, grant and trigger that guards the tables directly still guards '
  'them through here. The author is auth.uid() and is not a parameter.';

comment on function public.resubmit_report is
  'Replaces an editable report''s content, tools, and tags in one transaction. It does not '
  'unhide anything: status is reverted by the guard trigger, so revising is the author''s '
  'half of the exchange and unhiding stays a logged moderator decision.';

-- Postgres grants EXECUTE to PUBLIC on every new function, so each one needs an explicit
-- REVOKE. migrate.yml asserts in production that no browser role can reach anything in
-- `private`; these two are in `public` and are meant to be reachable by one role only.
revoke all on function public.submit_report from public;
grant execute on function public.submit_report to authenticated;

revoke all on function public.resubmit_report from public;
grant execute on function public.resubmit_report to authenticated;
