-- public.submit_practice() — one transaction for a practice, its tools, and its tags.
--
-- Why this has to exist
-- ---------------------
-- A practice must record at least one tool, enforced by a DEFERRABLE INITIALLY DEFERRED
-- constraint trigger. Deferred means "at the end of the transaction", and PostgREST gives
-- every request its own transaction. So a browser that inserts the practice and then its
-- tools in two requests fails on the first one, at commit, before the tools exist. There
-- is no ordering that works, because the tools reference a practice id that does not exist
-- until the practice is inserted.
--
-- One function is the whole fix. It is also the honest place for the rule: "a submission is
-- a practice, its tools and its tags, all or nothing" is a property of a submission, not of
-- a form, and a client that got the sequence wrong would produce half a contribution.
--
-- SECURITY INVOKER, and that is the point
-- ---------------------------------------
-- This is a transaction wrapper, not a privilege escalation. Running as the caller means
-- every policy written in the practices migrations still applies, unchanged: the insert
-- policy still requires a confirmed, unbanned account writing under its own id; the rate
-- limit trigger still fires; the column grants still hold. A DEFINER function here would
-- quietly become a hole around all of it, and would look exactly like this one.
--
-- author_id is taken from auth.uid() rather than accepted as a parameter. There is no
-- request shape that carries an author, for the same reason there is none that carries an
-- affiliation.

create function public.submit_practice(
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
  -- integer, although the column is smallint. Postgres will not implicitly narrow an
  -- integer literal to smallint while resolving which function to call, so a smallint
  -- parameter makes `submit_practice(..., 8, ...)` fail with "function does not exist" --
  -- a message that sends you looking for a missing migration rather than a missing cast.
  -- The assignment cast to the column happens on INSERT, where it is unambiguous, and the
  -- range is checked there by practices_author_confidence_range.
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}'
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

  if jsonb_array_length(p_tools) > 20 then
    raise exception 'That is more tools than one account of a session can usefully describe.'
      using errcode = '23514';
  end if;

  insert into public.practices (
    author_id, title, area, task_type, aim, method, outcome, outcome_notes, verification,
    transcript_excerpt, transcript_url, caveats, third_party_material_confirmed,
    time_spent_minutes, was_published, was_disclosed, author_confidence
  )
  values (
    -- Not a parameter, and never will be.
    (select auth.uid()),
    p_title, p_area, p_task_type, p_aim, p_method, p_outcome, p_outcome_notes,
    p_verification, p_transcript_excerpt, p_transcript_url, p_caveats,
    p_third_party_material_confirmed, p_time_spent_minutes, p_was_published,
    p_was_disclosed, p_author_confidence
  )
  returning id into v_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.practice_tools (practice_id, tool_name, tool_version, used_on)
    values (
      v_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date
    );
  end loop;

  -- Tags are matched by code rather than by id, so the client never has to know the uuids,
  -- and an unknown or retired code is silently dropped instead of failing a submission
  -- somebody spent ten minutes on. Retiring a tag between page load and submit is rare and
  -- losing a tag is a far smaller harm than losing the account of the work.
  insert into public.practice_tags (practice_id, tag_id)
  select v_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;

  return v_id;
end;
$$;

comment on function public.submit_practice is
  'Creates a practice with its tools and tags in one transaction, which the deferred '
  'at-least-one-tool constraint makes necessary. SECURITY INVOKER: every policy on the '
  'underlying tables still applies, and the author is auth.uid() rather than a parameter.';

-- Postgres grants EXECUTE to PUBLIC on every new function, so the revoke is not optional.
-- anon is deliberately absent from the grant: an anonymous caller has no author to be.
revoke all on function public.submit_practice from public;
grant execute on function public.submit_practice to authenticated;
