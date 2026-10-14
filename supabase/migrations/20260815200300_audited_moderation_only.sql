-- Moderation goes through public.moderate() or it does not happen.
--
-- Until this migration a moderator could hide a practice, promote a proposition or close a
-- report with an ordinary PostgREST call, because each of those tables carried a permissive
-- UPDATE policy for the moderator role. That was the right shape before there was an audit
-- log. It is the wrong shape now: "every moderation action writes an audit row" would be a
-- property of our own interface rather than of the database, and the first person to open a
-- console would be outside it. On a site whose readers check their own network tab, a log
-- that can be stepped around is worse than no log, because it invites trust it has not
-- earned.
--
-- So the four moderator UPDATE policies go, and with them the last unaudited path. What
-- remains on those tables is: anyone reads what is published, an author reads and edits
-- their own, and a moderator *reads* everything. Changing a row is the function's job.
--
-- The three guards are replaced at the same time and lose their moderator branches. Those
-- branches are now unreachable from a browser — no policy admits a moderator's UPDATE on
-- somebody else's row — and they are unnecessary to public.moderate(), which runs as the
-- table owner and takes the trusted path at the top of each guard. Leaving them would be
-- worse than dead code: it would mean that re-adding a moderator policy in some future
-- migration silently restored self-approval, quietly, with nothing in that migration
-- looking wrong. A moderator who reaches one of these triggers now is a moderator editing
-- their own row, and there they are an author like anybody else.

-- ── The policies ────────────────────────────────────────────────────────────────────

drop policy practices_update_moderator    on public.practices;
drop policy propositions_update_moderator on public.propositions;
drop policy comments_update_moderator     on public.comments;
drop policy reports_update_moderator      on public.reports;

-- The report columns lose their grant as well as their policy. On practices, propositions
-- and comments the status column keeps its grant on purpose — an author who writes it gets
-- it silently reverted by the guard, which is the documented behaviour of those tables and
-- what their tests assert. Here there is no such behaviour to preserve: nothing but a
-- moderator ever had reason to write these three columns, so the endpoint should refuse
-- rather than accept and discard.
revoke update (status, resolved_at, resolved_by) on public.reports from authenticated;

-- ── The practice guard ──────────────────────────────────────────────────────────────
-- Replaced rather than edited: migrations are append-only. Two changes from the version in
-- 20260815100200_practices.sql — the moderator branch is gone, and the three moderation
-- note columns are frozen for everyone the trusted check does not admit.

create or replace function private.protect_practice_columns()
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
  -- `authenticated` for a browser, and the table's owner when public.moderate() performs
  -- the update. As DEFINER this would always be the owner and the guard would never fire —
  -- which is the trap recorded in CLAUDE.md and the reason this line reads the way it does.
  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.practices'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for everyone. Reassigning an author would move a contribution onto somebody
  -- else's name, which is the one thing a corpus under CC BY must never do.
  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  -- Status is nobody's to set from a browser now. There is no moderator policy for this
  -- table any more, so the only callers reaching here are authors, and the queue is the
  -- only way out of pending.
  new.status := old.status;

  -- The change request belongs to the review, not to the author. It is written by
  -- public.moderate() and cleared when the practice is published; an author cannot remove
  -- the note asking them to fix something. There is no column grant either — this is the
  -- second lock, for the day somebody widens the first.
  new.moderation_note    := old.moderation_note;
  new.moderation_note_at := old.moderation_note_at;
  new.moderation_note_by := old.moderation_note_by;

  -- Restoring a deleted practice is a moderation action, not an authoring one. Without
  -- this, "delete" would be a toggle and a soft-deleted row could be brought back after
  -- the discussion around it had moved on.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- Past pending, the text is fixed. An account of what happened that can be rewritten
  -- after people have confirmed it still works is not a record of anything -- the
  -- confirmations would attest to a version nobody can read any more.
  if old.status <> 'pending' then
    new.title                          := old.title;
    new.area                           := old.area;
    new.task_type                      := old.task_type;
    new.aim                            := old.aim;
    new.method                         := old.method;
    new.outcome                        := old.outcome;
    new.outcome_notes                  := old.outcome_notes;
    new.verification                   := old.verification;
    new.transcript_excerpt             := old.transcript_excerpt;
    new.transcript_url                 := old.transcript_url;
    new.caveats                        := old.caveats;
    new.third_party_material_confirmed := old.third_party_material_confirmed;
    new.time_spent_minutes             := old.time_spent_minutes;
    new.was_published                  := old.was_published;
    new.was_disclosed                  := old.was_disclosed;
    new.author_confidence              := old.author_confidence;
  end if;

  return new;
end;
$$;

comment on function private.protect_practice_columns() is
  'Reverts writes to columns the caller does not own. SECURITY INVOKER: as DEFINER, '
  'current_user would always be the owner and the guard would never fire. Since the '
  'moderator UPDATE policy was dropped, everyone reaching here is an author.';

revoke all on function private.protect_practice_columns() from public;

-- ── The proposition guard ───────────────────────────────────────────────────────────

create or replace function private.protect_proposition_columns()
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
           where c.oid = 'public.propositions'::pg_catalog.regclass),
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

  -- The wording is fixed once anyone has rated it. People rated the sentence in front of
  -- them, and an author who could reword it afterwards would be reassigning their
  -- agreement to a claim they never saw.
  if exists (select 1 from public.ratings r where r.proposition_id = old.id) then
    new.statement := old.statement;
    new.area      := old.area;
  end if;

  return new;
end;
$$;

comment on function private.protect_proposition_columns() is
  'Reverts writes the caller does not own. SECURITY INVOKER: as DEFINER, current_user would '
  'always be the owner and the guard would never fire. Status and activation are '
  'public.moderate()''s alone.';

revoke all on function private.protect_proposition_columns() from public;

-- ── The comment guard ───────────────────────────────────────────────────────────────
-- The 24 hour edit window and the reply-freeze are unchanged, and the note explaining why
-- they live here rather than in a policy is worth repeating: permissive policies are OR'd,
-- so `comments_soft_delete_own` — which must permit an update at any age — would grant
-- exactly what a window written into `comments_update_own` withheld. A trigger is the only
-- single choke point an update has.

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
    if old.created_at <= now() - interval '24 hours' then
      raise exception
        'The edit window on a comment is 24 hours, and this one has passed. Post a '
        'follow-up comment instead — the thread keeps both.'
        using errcode = '23514';
    end if;

    -- And it closes early once anybody has answered. This is the same rule as a
    -- proposition whose wording freezes at its first rating: people replied to the
    -- sentence in front of them, and rewriting it afterwards makes their reply answer
    -- something they never read.
    if exists (select 1 from public.comments r where r.in_reply_to = old.id) then
      raise exception
        'This comment has replies, so its text is fixed. Post a follow-up instead.'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

comment on function private.protect_comment_columns() is
  'Reverts writes the caller does not own, performs the soft-delete erasure, and enforces '
  'the 24 hour edit window. SECURITY INVOKER; the window is here rather than in a policy '
  'because permissive policies are OR''d and the delete policy would grant round it.';

revoke all on function private.protect_comment_columns() from public;
