-- public.resubmit_practice() — replace a pending practice's content in one transaction.
--
-- The "send back for changes" loop was half a loop: moderators could ask for changes, and
-- authors could read the note, but there was nowhere to act on it. This function is the
-- other half — the author's side of the exchange.
--
-- Why this has to be a function
-- -----------------------------
-- The deferred at-least-one-tool constraint fires at COMMIT. Replacing the tool set means
-- deleting all existing rows and inserting the new ones. If those are two PostgREST
-- requests, each is its own transaction: the DELETE commits with zero tools and the
-- constraint fires immediately. Inside one function call they are one transaction, so the
-- constraint sees the final state — which has the new tools — and is satisfied.
--
-- This is exactly the same reasoning as submit_practice, so the same structure applies.
--
-- SECURITY INVOKER, and that is the point
-- ----------------------------------------
-- The caller's row-level security applies unchanged.
--   practices_update_own_pending  — refuses the UPDATE unless the practice is pending
--                                   and the author_id matches auth.uid().
--   practice_tools policies       — refuse INSERT and DELETE on tools for any other practice.
--   practice_tags policies        — same.
--
-- A DEFINER wrapper here would silently bypass all three, which is the trap the commentary
-- in private.protect_practice_columns() describes in detail. INVOKER is the correct choice
-- because there is no private schema access and no privilege escalation needed: the author
-- is editing their own pending work, and the policies already express exactly that.

create function public.resubmit_practice(
  p_practice_id                    uuid,
  p_title                          text,
  p_area                           public.practice_area,
  p_task_type                      public.practice_task_type,
  -- [{"name": "GPT-5", "version": "2026-05", "used_on": "2026-08-01"}, ...]
  p_tools                          jsonb,
  p_aim                            text,
  p_method                         text,
  p_outcome                        public.practice_outcome,
  p_outcome_notes                  text,
  p_verification                   text,
  p_third_party_material_confirmed boolean,
  p_transcript_excerpt             text     default null,
  p_transcript_url                 text     default null,
  p_caveats                        text     default null,
  p_time_spent_minutes             integer  default null,
  p_was_published                  boolean  default null,
  p_was_disclosed                  boolean  default null,
  -- integer rather than smallint, for the same reason as in submit_practice: Postgres
  -- cannot implicitly narrow an integer literal to smallint during overload resolution,
  -- producing a "function does not exist" error that looks like a missing migration.
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}'
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
  -- Validate tool count before touching anything, so the error message names the form
  -- field rather than a constraint. The deferred trigger is still the true enforcer.
  if p_tools is null
     or jsonb_typeof(p_tools) <> 'array'
     or jsonb_array_length(p_tools) = 0 then
    raise exception 'Record at least one tool, with its version and the date you used it.'
      using errcode = '23514';
  end if;

  if jsonb_array_length(p_tools) > 20 then
    raise exception 'That is more tools than one account of a session can usefully describe.'
      using errcode = '23514';
  end if;

  -- The update will match zero rows if the practice does not exist, is not pending, or is
  -- not owned by the caller (practices_update_own_pending refuses it). Check the count so
  -- the caller gets a clear error rather than silent success followed by a puzzling state.
  update public.practices set
    title                          = btrim(p_title),
    area                           = p_area,
    task_type                      = p_task_type,
    aim                            = btrim(p_aim),
    method                         = btrim(p_method),
    outcome                        = p_outcome,
    outcome_notes                  = btrim(p_outcome_notes),
    verification                   = btrim(p_verification),
    third_party_material_confirmed = p_third_party_material_confirmed,
    transcript_excerpt             = nullif(btrim(coalesce(p_transcript_excerpt, '')), ''),
    transcript_url                 = nullif(btrim(coalesce(p_transcript_url, '')), ''),
    caveats                        = nullif(btrim(coalesce(p_caveats, '')), ''),
    time_spent_minutes             = p_time_spent_minutes,
    was_published                  = p_was_published,
    was_disclosed                  = p_was_disclosed,
    author_confidence              = p_author_confidence
  where id = p_practice_id;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception 'This submission was not found, or it is no longer pending.'
      using errcode = 'P0002';
  end if;

  -- Replace tools atomically. The deferred constraint sees the final state — the new rows
  -- inserted below — rather than the empty intermediate. See the header.
  delete from public.practice_tools where practice_id = p_practice_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.practice_tools (practice_id, tool_name, tool_version, used_on)
    values (
      p_practice_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date
    );
  end loop;

  -- Replace tags. Unknown or retired codes are silently dropped, as in submit_practice.
  delete from public.practice_tags where practice_id = p_practice_id;

  insert into public.practice_tags (practice_id, tag_id)
  select p_practice_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;
end;
$$;

comment on function public.resubmit_practice is
  'Replaces a pending practice''s content, tools, and tags in one transaction — the deferred '
  'at-least-one-tool constraint makes the function necessary, for the same reason as '
  'submit_practice. SECURITY INVOKER: the caller''s policies are the only guards needed.';

-- Every new function gets EXECUTE on PUBLIC by default; remove it before granting narrowly.
revoke all on function public.resubmit_practice from public;
grant execute on function public.resubmit_practice to authenticated;
