-- public.moderate() — the only door into moderation, and the reason the log is complete.
--
-- One function rather than one per action. That is not tidiness: it is the single place
-- where "every action writes an audit row" can be made true rather than promised. The
-- effect and the log entry happen in one transaction, so there is no ordering of events in
-- which a practice is hidden and no row says who hid it, or in which a row claims a hide
-- that did not happen.
--
-- The migration after this one removes the moderator UPDATE policies that would otherwise
-- let the same person do the same thing through PostgREST without the log. Read the two
-- together: this is the door, that one bricks up the window.
--
-- SECURITY DEFINER, and this looks exactly like the trap CLAUDE.md warns about
-- ---------------------------------------------------------------------------
-- The trap is a DEFINER function that decides who the caller is by asking `current_user`.
-- Inside a DEFINER function that is the function's *owner*, so the check sees a trusted
-- answer on every browser request, and a guard written that way protects nothing while
-- reading in review as though it works. private.protect_profile_columns() is SECURITY
-- INVOKER for precisely that reason.
--
-- This function asks `auth.uid()`, which is a claim out of the caller's JWT and is
-- completely unaffected by SECURITY DEFINER: it is the same value here as in any row level
-- security policy on this site. So the authorisation below is real. DEFINER is needed for
-- the opposite reason to the one that makes it dangerous — the function must be able to
-- write rows the *caller* is not permitted to write, which is the entire point of routing
-- moderation through it.
--
-- What it will not do
-- -------------------
--   * It will not act on the caller's own practice, proposition or comment. A moderator's
--     contributions go through the same review as everybody else's, and self-approval is
--     the one shortcut that would make the queue meaningless. Another moderator decides.
--   * It will not ban a moderator or an admin. Demoting or banning someone with standing
--     is a change to make with direct database access, so that one compromised session
--     cannot disable the people who would notice.
--   * It will not let an admin erase their own account here, because the log would then
--     lose the hand that did it to the same cascade that removed the account.
--   * It will not erase an account that has not asked. The only route in is a pending row
--     in public.deletion_requests, which can only be written by the account holder.
--
-- No address of any kind is read, written, or returned anywhere below. The moderation
-- screen shows a display name and never anything a person could be contacted at.

create function public.moderate(
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
  v_actor       uuid := (select auth.uid());
  v_role        text;
  v_banned      boolean;
  v_reason      text := nullif(btrim(coalesce(p_reason, '')), '');
  v_author      uuid;
  v_status      text;
  v_target_role text;
  v_user        uuid;
  v_audit       uuid;
begin
  -- ── Who is asking ─────────────────────────────────────────────────────────────────
  -- auth.uid(), not current_user. See the header: this is what makes the check real.

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

  -- ── The reason ────────────────────────────────────────────────────────────────────
  -- Three actions take something away from somebody, and each has to be defensible six
  -- months later. The same rule is a CHECK on public.moderation_actions; this copy exists
  -- so the refusal arrives as a sentence rather than as a constraint name.

  if p_action in ('hide', 'request_changes', 'ban') and v_reason is null then
    raise exception
      'Hiding something, sending it back, and banning an account each need a reason. One sentence is enough, and it is kept.'
      using errcode = '23514';
  end if;

  -- ── Practices ─────────────────────────────────────────────────────────────────────

  if p_target_type = 'practice' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.practices x
     where x.id = p_target_id
       and x.deleted_at is null;

    if not found then
      raise exception 'That practice is no longer in the queue. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own submission, and it goes through the same review as anyone else''s. Another moderator has to decide it.'
        using errcode = '42501';
    end if;

    if p_action = 'publish' then
      if v_status <> 'pending' then
        raise exception 'Only a submission still waiting for review can be published.'
          using errcode = '23514';
      end if;

      -- Publishing clears any outstanding change request. The note described a version
      -- that has just been accepted, and leaving it would show the author a demand for
      -- changes on something already in the corpus.
      update public.practices
         set status             = 'published',
             moderation_note    = null,
             moderation_note_at = null,
             moderation_note_by = null
       where id = p_target_id;

    elsif p_action = 'request_changes' then
      if v_status <> 'pending' then
        raise exception
          'Changes can only be asked for while a submission is still waiting for review.'
          using errcode = '23514';
      end if;

      update public.practices
         set moderation_note    = v_reason,
             moderation_note_at = now(),
             moderation_note_by = v_actor
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That practice is already hidden.'
          using errcode = '23514';
      end if;

      update public.practices set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That practice is not hidden.'
          using errcode = '23514';
      end if;

      -- Unhiding publishes. Nothing records what the status was before it was hidden, and
      -- inventing one would be worse than the plain reading: a moderator unhiding
      -- something has the whole submission in front of them and is deciding it may be read.
      update public.practices set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a practice.'
        using errcode = '23514';
    end if;

  -- ── Propositions ──────────────────────────────────────────────────────────────────

  elsif p_target_type = 'proposition' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.propositions x
     where x.id = p_target_id;

    if not found then
      raise exception 'That proposition is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own proposition. Promoting it yourself is the shortcut this queue exists to prevent.'
        using errcode = '42501';
    end if;

    if p_action = 'promote' then
      if v_status <> 'proposed' then
        raise exception 'Only a proposed claim can be promoted.'
          using errcode = '23514';
      end if;

      update public.propositions
         set status = 'active', activated_at = now()
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That proposition is already hidden.'
          using errcode = '23514';
      end if;

      -- activated_at goes with it. propositions_activated_iff_active ties the date to the
      -- status, so a hidden proposition cannot keep one.
      update public.propositions
         set status = 'hidden', activated_at = null
       where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That proposition is not hidden.'
          using errcode = '23514';
      end if;

      -- Back to proposed rather than straight to active: it was hidden for a reason, and
      -- rejoining the record is a second decision somebody should have to take.
      update public.propositions
         set status = 'proposed', activated_at = null
       where id = p_target_id;

    else
      raise exception 'That action does not apply to a proposition.'
        using errcode = '23514';
    end if;

  -- ── Comments ──────────────────────────────────────────────────────────────────────
  -- Hiding is the only power over a comment, and it preserves the text and the name. That
  -- is what makes it reviewable and reversible; editing somebody else's words under their
  -- name is not a moderation action in any tradition worth copying.

  elsif p_target_type = 'comment' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.comments x
     where x.id = p_target_id;

    if not found then
      raise exception 'That comment is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own comment. Delete it as its author instead — that is a different act and it is recorded as one.'
        using errcode = '42501';
    end if;

    if p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That comment is already hidden.'
          using errcode = '23514';
      end if;

      update public.comments set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That comment is not hidden.'
          using errcode = '23514';
      end if;

      update public.comments set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a comment.'
        using errcode = '23514';
    end if;

  -- ── Reports ───────────────────────────────────────────────────────────────────────
  -- Resolving a report is a decision about the report, not about the thing it named.
  -- Hiding the practice and closing the report are two actions and produce two rows,
  -- because "we agreed and acted" and "we looked and did nothing" are the two answers a
  -- reporter is owed and they have to be distinguishable afterwards.

  elsif p_target_type = 'report' then
    select r.status::text
      into v_status
      from public.reports r
     where r.id = p_target_id;

    if not found then
      raise exception 'That report is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_status <> 'open' then
      raise exception 'That report has already been dealt with.'
        using errcode = '23514';
    end if;

    if p_action not in ('resolve_report', 'dismiss_report') then
      raise exception 'That action does not apply to a report.'
        using errcode = '23514';
    end if;

    update public.reports
       set status = case when p_action = 'resolve_report'
                         then 'actioned'::public.report_status
                         else 'dismissed'::public.report_status
                    end,
           resolved_at = now(),
           resolved_by = v_actor
     where id = p_target_id;

  -- ── Accounts ──────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'account' then

    if p_action in ('ban', 'unban') then
      if p_target_id = v_actor then
        raise exception 'An account cannot ban itself.'
          using errcode = '42501';
      end if;

      select p.role
        into v_target_role
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

      update public.profiles
         set is_banned = (p_action = 'ban')
       where id = p_target_id;

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

      -- The whole erasure, in one statement, because every rule about what survives is
      -- already written into the foreign keys:
      --
      --   public.profiles          cascades away with the account
      --   practices, comments      author_id becomes null; the corpus keeps the work
      --   ratings, confirmations   cascade away; they are answers, not contributions
      --   citations, reports       the hand is stripped, the link and the queue stand
      --   deletion_requests        cascades, which is correct: after the erasure there
      --                            must be no row saying this person asked to be erased
      --
      -- Nothing here is a special case written for this function, and that is the point:
      -- the erasure path is the same one the schema has described since the beginning.
      delete from auth.users u where u.id = v_user;

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

  -- ── The record ────────────────────────────────────────────────────────────────────
  -- One transaction with the effect above, so the two cannot come apart. An erasure logs
  -- that it happened and refuses to log whose; see the constraint on the table.

  insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
  values (
    v_actor,
    p_action,
    p_target_type,
    case when p_action = 'erase_account' then null else p_target_id end,
    v_reason
  )
  returning id into v_audit;

  return v_audit;
end;
$$;

comment on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) is
  'The only audited route for a moderation decision. SECURITY DEFINER so it can write rows '
  'the caller cannot, and it authorises on auth.uid() rather than current_user, which is '
  'what makes that safe. Refuses to act on the caller''s own content.';

-- Postgres grants EXECUTE to PUBLIC on every new function, which would put this in reach of
-- an anonymous caller. The revoke is what actually closes it; the grant then opens it to
-- exactly one role, and the checks above decide the rest.
revoke all on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) from public;
grant execute on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) to authenticated;
