-- Backfill public.activity from the history that is already in the database.
--
-- The feature shipped and every existing account saw "Nothing here yet". That is what a
-- trigger does: it observes statements, and every report, debate, comment, rating, flag and
-- moderation decision made before 20260818120100 happened without anything watching. The
-- page was telling the truth about an empty table, which is the worst kind of correct — it
-- reads as a broken feature to the one audience least inclined to give it a second try.
--
-- Almost all of it is recoverable, because every source table carries created_at and
-- public.moderation_actions is a complete log of what was decided and when. So the feed is
-- reconstructed with its real dates rather than stamped with the date of this migration,
-- which would have been a lie in a column people read as history.
--
-- The one thing that cannot be recovered is 'edited_report': there is no revision history,
-- by the deliberate decision in docs/moderation.md, so an edit made before today leaves no
-- trace to find. Nothing else is missing.
--
-- Three changes, in order:
--
--   1. private.log_activity() gains p_created_at, so a backfilled row can carry the date of
--      the thing it describes, and a dedup guard, so it can be run twice — or run over rows
--      the triggers have already seen — without writing anything twice.
--   2. The moderation mapping moves out of the trigger into private.log_moderation(). A
--      trigger function cannot be called outside a trigger, so without this the backfill
--      would need its own copy of the longest and most error-prone routing in the feature.
--      The trigger becomes a wrapper; its behaviour is unchanged and the pgTAP assertions
--      that cover it are unchanged too.
--   3. private.backfill_activity() walks every source table. It is a function rather than a
--      DO block so that it is testable and so that it can be run again by hand if a later
--      import ever needs it.

-- ── 1. A row can be dated, and cannot be written twice ──────────────────────────────
-- Dropped and recreated rather than replaced: adding a parameter creates an overload rather
-- than replacing the function, and a seven-argument call would then match two candidates.
-- The trigger functions call this by name from plpgsql, which resolves at runtime, so none
-- of them needs reissuing.

drop function private.log_activity(uuid, public.activity_kind, uuid,
                                   public.moderation_target, uuid, uuid, text);

create function private.log_activity(
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
    when 'posted_debate'    then v_inbound := false;
    when 'posted_entry'     then v_inbound := false;
    when 'commented'        then v_inbound := false;
    when 'rated_debate'     then v_inbound := false;
    when 'confirmed_report' then v_inbound := false;
    when 'flagged'          then v_inbound := false;
    when 'cited'            then v_inbound := false;

    when 'report_published'         then v_inbound := true;
    when 'report_changes_requested' then v_inbound := true;
    when 'entry_published'          then v_inbound := true;
    when 'entry_changes_requested'  then v_inbound := true;
    when 'debate_promoted'          then v_inbound := true;
    when 'content_hidden'           then v_inbound := true;
    when 'content_unhidden'         then v_inbound := true;
    when 'account_banned'           then v_inbound := true;
    when 'account_unbanned'         then v_inbound := true;
    when 'flag_resolved'            then v_inbound := true;
    when 'flag_dismissed'           then v_inbound := true;
    when 'content_commented'        then v_inbound := true;
    when 'comment_reply'            then v_inbound := true;
    when 'debate_rated'             then v_inbound := true;
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
  -- and the pairs that genuinely collide otherwise (two people rating one debate, several
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
    -- capped well below 200 characters but a debate statement is not, and a notification
    -- is not the place a length rule should first be discovered.
    nullif(left(btrim(coalesce(p_label, '')), 200), ''),
    v_at
  );
end;
$$;

comment on function private.log_activity(uuid, public.activity_kind, uuid,
                                         public.moderation_target, uuid, uuid, text,
                                         timestamptz) is
  'The only writer of public.activity. Classifies the kind, refuses to notify somebody '
  'about their own act, dates the row, and refuses to write a backfilled duplicate.';

revoke all on function private.log_activity(uuid, public.activity_kind, uuid,
                                            public.moderation_target, uuid, uuid, text,
                                            timestamptz)
  from public;

-- ── 2. The moderation mapping, out of the trigger ───────────────────────────────────
-- Identical to what the trigger did, taking the three fields of an audit row instead of NEW.
-- A trigger function cannot be called outside a trigger, and the alternative was a second
-- copy of this routing inside the backfill — the longest branch in the feature, and the one
-- where a mistake writes a wrong notification to a real person permanently.
--
-- The actor is null in every branch, and that is the design rather than an oversight. The
-- author is told what was decided about their work, never by whom.

create function private.log_moderation(
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

  elsif p_target_type = 'debate' then
    select x.author_id, x.statement into v_subject, v_label
      from public.debates x where x.id = p_target_id;

    v_kind := case p_action
      when 'promote' then 'debate_promoted'
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
    -- asked for the decision rather than the person it was about.
    select f.flagger_id, private.activity_label(private.as_target(f.subject_type), f.subject_id)
      into v_subject, v_label
      from public.flags f where f.id = p_target_id;

    v_kind := case p_action
      when 'resolve_flag' then 'flag_resolved'
      when 'dismiss_flag' then 'flag_dismissed'
    end;

  elsif p_target_type = 'account' then
    v_subject := p_target_id;

    v_kind := case p_action
      when 'ban'   then 'account_banned'
      when 'unban' then 'account_unbanned'
    end;
  end if;

  -- An action with no notification attached to it — there is none today, but a value added
  -- to public.moderation_action later will land here rather than raise. A missing
  -- notification is the right failure for a log that has already recorded the decision:
  -- the audit row is the record, and this table is a courtesy.
  if v_kind is null then
    return;
  end if;

  perform private.log_activity(
    v_subject, v_kind, null, v_target, v_target_id, v_comment_id, v_label, p_created_at
  );
end;
$$;

comment on function private.log_moderation(public.moderation_action,
                                           public.moderation_target, uuid, timestamptz) is
  'Turns one moderation decision into at most one feed row for the person it was about. '
  'Never names the moderator and never copies the reason. Called by the trigger on '
  'public.moderation_actions and by private.backfill_activity().';

revoke all on function private.log_moderation(public.moderation_action,
                                              public.moderation_target, uuid, timestamptz)
  from public;

-- The trigger is now a wrapper. Behaviour is unchanged: it passes the audit row's own
-- created_at, which inside the firing transaction is the same value now() would give.
create or replace function private.activity_on_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_moderation(
    new.action, new.target_type, new.target_id, new.created_at
  );

  return null;
end;
$$;

comment on function private.activity_on_moderation() is
  'Trigger wrapper around private.log_moderation(). One audit row in, at most one feed row '
  'out.';

-- ── 3. The backfill ─────────────────────────────────────────────────────────────────
-- Every source table, in the order the feed would have been written. Each loop mirrors the
-- trigger of the same name; the routing is short enough in each case that repeating it here
-- is cheaper than seven more extracted functions, and private.log_activity() is still the
-- only thing that decides what counts as unread and who may not be told.
--
-- Soft-deleted rows are included. A report the author deleted still happened, and "you
-- posted this" is the record rather than the content. Rows whose person was erased fall out
-- on their own: author_id is null, and log_activity() returns without writing.

create function private.backfill_activity()
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

  -- Reports, debates and entries: what each person posted.
  for v_row in select id, author_id, title, created_at from public.reports order by created_at
  loop
    perform private.log_activity(
      v_row.author_id, 'posted_report', v_row.author_id, 'report', v_row.id,
      null, v_row.title, v_row.created_at
    );
  end loop;

  for v_row in select id, author_id, statement, created_at from public.debates order by created_at
  loop
    perform private.log_activity(
      v_row.author_id, 'posted_debate', v_row.author_id, 'debate', v_row.id,
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
        select x.author_id into v_owner from public.debates x where x.id = v_row.parent_id;
      end if;

      perform private.log_activity(
        v_owner, 'content_commented', v_row.author_id, v_target, v_row.parent_id,
        v_row.id, v_label, v_row.created_at
      );
    end if;
  end loop;

  -- Ratings. The author is never told who, and an explicit "no opinion" is not a rating.
  for v_row in
    select r.debate_id, r.user_id, r.score, r.created_at, d.author_id, d.statement
      from public.ratings r
      join public.debates d on d.id = r.debate_id
     order by r.created_at
  loop
    perform private.log_activity(
      v_row.user_id, 'rated_debate', v_row.user_id, 'debate', v_row.debate_id,
      null, v_row.statement, v_row.created_at
    );

    if v_row.score is not null and v_row.author_id is distinct from v_row.user_id then
      perform private.log_activity(
        v_row.author_id, 'debate_rated', null, 'debate', v_row.debate_id,
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
      select x.author_id into v_owner from public.debates x where x.id = v_row.target_id;
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

comment on function private.backfill_activity() is
  'Reconstructs public.activity from the history in the other tables. Idempotent: every '
  'write goes through private.log_activity() with a date, which refuses a duplicate.';

revoke all on function private.backfill_activity() from public;

-- Run it.
do $$
declare
  v_written integer;
begin
  v_written := private.backfill_activity();
  raise notice 'Backfilled % activity row(s) from existing content.', v_written;
end;
$$;
