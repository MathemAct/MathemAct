-- Change was_published from boolean to text.
--
-- The boolean gave three states: true (yes), false (no), null (not yet or not applicable).
-- "Not yet" and "not applicable" are genuinely different answers — a paper on a teaching
-- session that was never going to be published is not the same as a paper that the author
-- still expects to submit. Splitting null into 'not_yet' and 'not_applicable' requires a
-- fourth state, and boolean has three.
--
-- The corpus is empty at the time of this migration (practices.sql created the column and
-- 20260820100000 deleted all rows), so the USING clause is informational rather than a
-- real data migration.

-- Drop the old table constraint first: it references was_published as boolean and cannot
-- survive a column drop. Postgres would drop it automatically along with the column, but
-- naming it here makes the migration easier to read and is consistent with adding its
-- replacement explicitly below.
--
-- The constraint was created as practices_disclosure_needs_publication and renamed to
-- reports_disclosure_needs_publication by 20260817130000_rename_vocabulary.sql.
alter table public.reports
  drop constraint reports_disclosure_needs_publication;

-- Drop and re-add the column. ALTER COLUMN ... USING does not work here because the local
-- Postgres version evaluates the USING expression with the column already cast to the new
-- type, which means boolean predicates inside it fail. Since the corpus is empty at this
-- point (20260820100000 deleted all rows), dropping and re-adding loses no data.
alter table public.reports
  drop column was_published,
  add column was_published text;

alter table public.reports
  add constraint reports_was_published_values
    check (was_published in ('yes', 'not_yet', 'no', 'not_applicable'));

alter table public.reports
  add constraint reports_disclosure_needs_publication
    check (was_disclosed is null or was_published = 'yes');

-- INSERT and UPDATE on public.reports are granted per column, so dropping the column took
-- its grants with it and re-adding it does not bring them back. Nothing warns you: the
-- column is there, the constraint is there, the policy matches, and submit_report -- which
-- is SECURITY INVOKER precisely so that the grants still apply through it -- dies with
-- "permission denied for table reports" on every submission. Regrant the one column.
grant insert (was_published) on public.reports to authenticated;
grant update (was_published) on public.reports to authenticated;

-- Both RPCs carry p_was_published boolean. Changing a parameter type is a signature change:
-- create or replace would leave the old signature as a second overload and every call
-- would then be ambiguous. Drop and recreate.
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
    author_confidence, rating_helpfulness, rating_time_saved, rating_trust_before_checking,
    rating_verification_effort, rating_novelty, rating_understanding_gained,
    cost_more_time_than_saved, generalises
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
