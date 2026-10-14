-- One private.log_activity(), and one moderation mapping again.
--
-- 20260818180000_flag_led_moderation.sql reissued private.log_activity() to add a branch for
-- the `content_kept` kind, and reissued it **with the seven-parameter signature it had two
-- migrations earlier**. 20260818140000 had already dropped that signature and replaced it
-- with an eight-parameter one carrying `p_created_at`. So `create or replace` did not
-- replace anything: it created a second overload whose eighth parameter simply does not
-- exist, and every seven-argument call — which is every call from every trigger — became
-- ambiguous.
--
--   ERROR: function private.log_activity(uuid, unknown, uuid, unknown, uuid, unknown, text)
--          is not unique
--
-- The effect in production is total and was invisible until something tried to write:
-- posting a report, a debate, an entry, a comment, a rating, a confirmation, a flag or a
-- citation all fire a trigger that calls this function, so **every content write on the site
-- failed** from the moment the migration applied. Reading was untouched, which is exactly
-- why it got as far as it did: the site is served from static files and looked perfectly
-- healthy. `test-db.yml` caught it — ten of nineteen test files died on their first INSERT —
-- and `migrate.yml`, which runs on the same push rather than after it, had already applied
-- it.
--
-- The lesson, recorded in CLAUDE.md rather than only here: **`create or replace function` is
-- not idempotent across a signature change.** Adding or removing a parameter makes a new
-- function, and the old one stays. Before reissuing any function, check what the *latest*
-- migration touching it left behind, not the one that created it.
--
-- Three things are fixed here.
--
--   1. The seven-argument overload is dropped, and the eight-argument one is reissued with
--      the `content_kept` branch it was supposed to get.
--   2. `content_kept` joins the kinds allowed to carry a comment_id, which it needs when the
--      flag that was dismissed was a flag against a comment.
--   3. The moderation mapping goes back where 20260818140000 put it. That migration moved it
--      out of the trigger into private.log_moderation() so that the trigger and
--      private.backfill_activity() could not drift apart; the flag-led migration then
--      inlined a new copy into the trigger and left log_moderation() holding the old one.
--      Nothing was broken by that — the trigger is what fires in practice — but it is two
--      mappings again, and the one the backfill uses is the stale one.

-- ── 1. The overload that should not exist ───────────────────────────────────────────
-- No `if exists`. If this signature is already gone, something has happened that nobody
-- writing this migration understood, and failing loudly is the correct outcome.

drop function private.log_activity(uuid, public.activity_kind, uuid,
                                   public.moderation_target, uuid, uuid, text);

-- ── 2. The real one, with the branch it was meant to get ────────────────────────────
-- Identical to 20260818140000's definition except for one line: `content_kept`, the kind
-- that tells an author their post was flagged and left where it was. The CASE has no ELSE,
-- so without the branch the first dismissal would have raised CASE_NOT_FOUND rather than
-- quietly writing an unread-less row — the failure this file is otherwise about.

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
    when 'posted_debate'    then v_inbound := false;
    when 'posted_entry'     then v_inbound := false;
    when 'commented'        then v_inbound := false;
    when 'rated_debate'     then v_inbound := false;
    when 'confirmed_report' then v_inbound := false;
    when 'flagged'          then v_inbound := false;
    when 'cited'            then v_inbound := false;

    -- The first four and debate_promoted are pre-moderation history. Nothing writes them
    -- since the gate was removed; feeds built before that still carry them, so a branch
    -- removed here would break reading rather than writing.
    when 'report_published'         then v_inbound := true;
    when 'report_changes_requested' then v_inbound := true;
    when 'entry_published'          then v_inbound := true;
    when 'entry_changes_requested'  then v_inbound := true;
    when 'debate_promoted'          then v_inbound := true;
    when 'content_hidden'           then v_inbound := true;
    when 'content_unhidden'         then v_inbound := true;
    when 'content_kept'             then v_inbound := true;
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
  'The only writer of public.activity, and the only overload of this name — see '
  '20260819090000 for what happens when there are two. Classifies the kind, refuses to '
  'notify somebody about their own act, dates the row, and refuses to write a backfilled '
  'duplicate.';

-- Postgres grants EXECUTE to PUBLIC on every new function. This one already exists and
-- `create or replace` leaves its privileges alone, so the revoke below changes nothing
-- today — it is here because the day somebody drops and recreates this function, the line
-- being present is the difference between a private function and a public one.
revoke all on function private.log_activity(uuid, public.activity_kind, uuid,
                                            public.moderation_target, uuid, uuid, text,
                                            timestamptz)
  from public;

-- ── 3. A kept comment may say which comment ─────────────────────────────────────────
-- public.activity restricts which kinds may carry a comment_id, because a comment id on an
-- event that is not about a comment produces a link with a dangling fragment — a page that
-- looks broken rather than a row that looks wrong. `content_kept` was added to the enum
-- without being added to that list, and a flag dismissed against a *comment* writes exactly
-- that row: the author is told their comment was looked at and left alone, and the link
-- needs the fragment to find it. It is the same shape as `content_hidden`, which is already
-- in the list for the same reason.
--
-- Validated rather than NOT VALID: the rule is being widened, so every existing row already
-- satisfies it, and there is no history here to protect from a rule it predates.

alter table public.activity drop constraint activity_comment_id_relevant;

alter table public.activity
  add constraint activity_comment_id_relevant
    check (
      comment_id is null
      or kind in ('commented', 'content_commented', 'comment_reply', 'content_hidden',
                  'content_unhidden', 'content_kept')
    );

comment on constraint activity_comment_id_relevant on public.activity is
  'A comment id belongs only to the events that are about a comment. Anything else would '
  'render as a link with a dangling fragment.';

-- ── 4. One moderation mapping, back where it belongs ────────────────────────────────
-- private.log_moderation() is called by the trigger on public.moderation_actions and by
-- private.backfill_activity(). The flag-led migration inlined its own copy into the trigger
-- and left this one describing the world before post-moderation, which is a slow way to be
-- wrong: the trigger is what fires, so nothing looks broken until somebody runs the backfill
-- and gets notifications built from a mapping two weeks out of date.
--
-- What is new here relative to 20260818140000, beyond deleting nothing:
--
--   * **A dismissal writes two rows.** The flagger is told their flag was answered, and the
--     author is told their post was looked at and left alone. That second row is the one
--     place a content author learns a flag existed at all — deliberate, and it still never
--     says who raised it.
--   * The `publish`, `request_changes` and `promote` branches stay. Nothing writes those
--     actions any more, but the audit log is full of them and this function is what the
--     backfill reads it with.

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
      elsif v_kept = 'debate' then
        select x.author_id into v_author from public.debates x where x.id = v_kept_id;
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

comment on function private.log_moderation(public.moderation_action,
                                           public.moderation_target, uuid, timestamptz) is
  'Turns one moderation decision into the feed rows the people it was about are owed: one '
  'for the author or the flagger, and two when a flag is dismissed. Never names the '
  'moderator, never names the flagger, and never copies the reason — that reaches them as '
  'public.moderation_notices. Called by the trigger on public.moderation_actions and by '
  'private.backfill_activity().';

revoke all on function private.log_moderation(public.moderation_action,
                                              public.moderation_target, uuid, timestamptz)
  from public;

-- The trigger goes back to being a wrapper, which is what it was before the flag-led
-- migration inlined a copy of the mapping into it. One mapping, two callers.
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
  'Trigger wrapper around private.log_moderation(). One audit row in, the feed rows the '
  'people it was about are owed out.';
