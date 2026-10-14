-- Replace rating_time_saved (0-to-10) and cost_more_time_than_saved (boolean) with
-- time_saved (text), which takes eight ordered values.
--
-- A 0-to-10 scale asked "how much time did it save", but "it cost me more time than it
-- saved" is below the floor and "I saved a full day" is qualitatively different from "I
-- saved a few minutes": the two bits of information the old pair held together are now a
-- single ordered choice that fits without a separate checkbox beside it.

alter table public.reports
  drop column rating_time_saved,
  drop column cost_more_time_than_saved;

alter table public.reports
  add column time_saved text;

alter table public.reports
  add constraint reports_time_saved_values
    check (time_saved in (
      'cost_more', 'none', 'few_minutes', 'few_hours',
      'full_day', 'few_days', 'about_a_week', 'more'
    ));

-- INSERT and UPDATE on public.reports are granted per column, so a new column arrives with
-- no privilege at all and the two it replaces took theirs with them. Without this,
-- submit_report -- SECURITY INVOKER, so the grants apply through it -- fails every
-- submission with "permission denied for table reports", which reads as a policy problem
-- and is not one.
grant insert (time_saved) on public.reports to authenticated;
grant update (time_saved) on public.reports to authenticated;

-- The freeze list names every column an author may not change once somebody else has
-- answered the report. A column missing from the list can be rewritten after a
-- confirmation has attested to a version. Reissue the whole function rather than patching:
-- a guard read in two halves is a guard read wrong.
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
  end if;

  return new;
end;
$$;

-- Both RPCs carried p_rating_time_saved and p_cost_more_time_than_saved. Each parameter
-- removal is a signature change; create or replace would leave ghost overloads.
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

  insert into public.reports (
    author_id, title, area, area_other, task_type, task_secondary, career_stage,
    aim, method, outcome, outcome_notes, verification,
    prompts, transcript_excerpt, transcript_url, "references", caveats,
    third_party_material_confirmed, time_spent_minutes, was_published, was_disclosed,
    author_confidence, rating_helpfulness, time_saved, rating_trust_before_checking,
    rating_verification_effort, rating_novelty, rating_understanding_gained,
    generalises
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

  if p_references is not null
     and jsonb_typeof(p_references) = 'array'
     and jsonb_array_length(p_references) > 8 then
    raise exception 'Eight supporting links is the most. Pick the ones a reader would actually follow.'
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
    generalises                    = nullif(btrim(coalesce(p_generalises, '')), '')
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
