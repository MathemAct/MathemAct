-- Schema version 3 of a report: a sixteenth, optional section, "Did you learn something new?".
--
-- What this is for. The two conditional scales (novelty, understanding gained) measure what the
-- tool contributed and are shown only for some areas and task types. Neither lets an author say
-- plainly that they came away knowing something they did not know before -- about the
-- mathematics, about the tool, or about how to work with it -- and neither carries a sentence.
-- A failed attempt that taught something is one of the most useful accounts this corpus can
-- hold, and until now it had nowhere to say so.
--
-- Two columns, both nullable:
--
--   `learned_something` is a boolean. Null means the question was not answered, which is not
--   the same as "no" and must never be read as it: the form shows nothing selected on load, as
--   it does for the scales, so that the unanswered state is a real one.
--
--   `learned_notes` is free text, capped at 1000 characters to match REPORT_LIMITS.learnedNotes.
--   It is allowed only alongside an answer. A note elaborates on a yes or a no; without one it
--   is text in the export that explains nothing, and the form says "answer first" before the
--   database has to.
--
-- Three things in here worth reading before changing any of it
-- ----------------------------------------------------------
--
--   1. **The grants are issued here.** INSERT and UPDATE on public.reports are per column, so a
--      new column arrives with no privilege at all, and submit_report -- SECURITY INVOKER --
--      would fail every submission with "permission denied for table reports", which reads as a
--      policy problem and is not one.
--
--   2. **Both columns join the guard's freeze list.** A column that list does not name can be
--      rewritten after somebody has confirmed the report, silently. Reissued in full, from the
--      latest definition (20260820130000), rather than patched.
--
--   3. **`schema_version` default moves to 3, and existing rows stay at 2.** A version-2 row
--      was never asked this question, and the number is how an analysis tells that from a
--      version-3 row that was asked and left blank. The guard freezes schema_version, so a
--      version-2 report edited later to add an answer stays at 2. That is a small untruth in a
--      rare case and the alternative -- letting a caller move the version -- is worse.

-- ── 1. The columns ──────────────────────────────────────────────────────────────────

alter table public.reports
  add column learned_something boolean,
  add column learned_notes     text;

alter table public.reports
  alter column schema_version set default 3;

alter table public.reports
  add constraint reports_learned_notes_length
    check (learned_notes is null or length(btrim(learned_notes)) between 1 and 1000),

  -- One direction only. An answer without a note is the common case and is fine.
  add constraint reports_learned_notes_need_an_answer
    check (learned_notes is null or learned_something is not null);

comment on column public.reports.learned_something is
  'Did the author learn something new -- about the mathematics, the tool, or how to work with '
  'it. Null means unanswered, never "no". Shown for every outcome, failures included.';
comment on column public.reports.learned_notes is
  'Optional elaboration on learned_something. Present only when learned_something is not null.';
comment on column public.reports.schema_version is
  'Which version of the reporting standard this row was written against. Bumped by a '
  'migration when a field or a vocabulary changes; never written by a caller. Version 3 added '
  'learned_something and learned_notes.';

-- ── 2. Grants ───────────────────────────────────────────────────────────────────────
grant insert (learned_something, learned_notes) on public.reports to authenticated;
grant update (learned_something, learned_notes) on public.reports to authenticated;

-- ── 3. The guard, reissued ──────────────────────────────────────────────────────────
-- Identical to 20260820130000 except for the last two assignments in the freeze list.

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

  -- SECURITY INVOKER, so current_user is whoever is actually running the statement. As DEFINER
  -- this would always be the owner and the guard would never fire.
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

  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;
  new.schema_version := old.schema_version;
  new.status := old.status;
  new.answered_at := old.answered_at;

  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

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
    new.time_saved                     := old.time_saved;
    new.rating_trust_before_checking   := old.rating_trust_before_checking;
    new.rating_verification_effort     := old.rating_verification_effort;
    new.rating_novelty                 := old.rating_novelty;
    new.rating_understanding_gained    := old.rating_understanding_gained;
    new.generalises                    := old.generalises;
    new.learned_something              := old.learned_something;
    new.learned_notes                  := old.learned_notes;
  end if;

  return new;
end;
$$;

comment on function private.protect_report_columns() is
  'Reverts writes to columns the caller does not own. Text is editable while the report is '
  'hidden, and until answered_at is set. Deliberately SECURITY INVOKER: as DEFINER, '
  'current_user would always be the owner and the guard would never fire.';

-- ── 4. submit_report and resubmit_report ────────────────────────────────────────────
-- Dropped and recreated, not replaced: adding a parameter under create or replace creates a
-- second function, and every call that fits both fails with "function is not unique". The two
-- new parameters are appended last and defaulted, so a positional call written against the old
-- signature still resolves.

drop function public.submit_report;
drop function public.resubmit_report;

create function public.submit_report(
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
  p_was_published                  text     default null,
  p_was_disclosed                  boolean  default null,
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}',
  p_area_other                     text     default null,
  p_task_secondary                 text[]   default '{}',
  p_career_stage                   text     default null,
  p_prompts                        text     default null,
  p_references                     jsonb    default '[]'::jsonb,
  p_rating_helpfulness             integer  default null,
  p_time_saved                     text     default null,
  p_rating_trust_before_checking   integer  default null,
  p_rating_verification_effort     integer  default null,
  p_rating_novelty                 integer  default null,
  p_rating_understanding_gained    integer  default null,
  p_generalises                    text     default null,
  -- Arrived with schema version 3.
  p_learned_something              boolean  default null,
  p_learned_notes                  text     default null
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

  if p_references is not null
     and jsonb_typeof(p_references) = 'array'
     and jsonb_array_length(p_references) > 8 then
    raise exception 'Eight supporting links is the most. Pick the ones a reader would actually follow.'
      using errcode = '23514';
  end if;

  -- Said here as a sentence about the form; reports_learned_notes_need_an_answer is the truth.
  if p_learned_something is null and nullif(btrim(coalesce(p_learned_notes, '')), '') is not null then
    raise exception 'Answer yes or no to "Did you learn something new?" before adding a note to it.'
      using errcode = '23514';
  end if;

  insert into public.reports (
    author_id, title, area, area_other, task_type, task_secondary, career_stage,
    aim, method, outcome, outcome_notes, verification,
    prompts, transcript_excerpt, transcript_url, "references", caveats,
    third_party_material_confirmed, time_spent_minutes, was_published, was_disclosed,
    author_confidence, rating_helpfulness, time_saved, rating_trust_before_checking,
    rating_verification_effort, rating_novelty, rating_understanding_gained,
    generalises, learned_something, learned_notes
  )
  values (
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
    p_rating_helpfulness, p_time_saved, p_rating_trust_before_checking,
    p_rating_verification_effort, p_rating_novelty, p_rating_understanding_gained,
    nullif(btrim(coalesce(p_generalises, '')), ''),
    p_learned_something,
    nullif(btrim(coalesce(p_learned_notes, '')), '')
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
  p_was_published                  text     default null,
  p_was_disclosed                  boolean  default null,
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}',
  p_area_other                     text     default null,
  p_task_secondary                 text[]   default '{}',
  p_career_stage                   text     default null,
  p_prompts                        text     default null,
  p_references                     jsonb    default '[]'::jsonb,
  p_rating_helpfulness             integer  default null,
  p_time_saved                     text     default null,
  p_rating_trust_before_checking   integer  default null,
  p_rating_verification_effort     integer  default null,
  p_rating_novelty                 integer  default null,
  p_rating_understanding_gained    integer  default null,
  p_generalises                    text     default null,
  p_learned_something              boolean  default null,
  p_learned_notes                  text     default null
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

  if p_references is not null
     and jsonb_typeof(p_references) = 'array'
     and jsonb_array_length(p_references) > 8 then
    raise exception 'Eight supporting links is the most. Pick the ones a reader would actually follow.'
      using errcode = '23514';
  end if;

  if p_learned_something is null and nullif(btrim(coalesce(p_learned_notes, '')), '') is not null then
    raise exception 'Answer yes or no to "Did you learn something new?" before adding a note to it.'
      using errcode = '23514';
  end if;

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
    time_saved                     = p_time_saved,
    rating_trust_before_checking   = p_rating_trust_before_checking,
    rating_verification_effort     = p_rating_verification_effort,
    rating_novelty                 = p_rating_novelty,
    rating_understanding_gained    = p_rating_understanding_gained,
    generalises                    = nullif(btrim(coalesce(p_generalises, '')), ''),
    learned_something              = p_learned_something,
    learned_notes                  = nullif(btrim(coalesce(p_learned_notes, '')), '')
  where id = p_report_id;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception
      'This report was not found, or it can no longer be edited. A report is editable while it is hidden, and until somebody else has confirmed or commented on it — after that the text is fixed, because their answer attests to a version.'
      using errcode = 'P0002';
  end if;

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

revoke all on function public.submit_report from public;
grant execute on function public.submit_report to authenticated;

revoke all on function public.resubmit_report from public;
grant execute on function public.resubmit_report to authenticated;
