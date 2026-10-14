-- The nine triggers that fill public.activity.
--
-- Every one of them is AFTER INSERT (the one exception is noted where it is), every one is
-- SECURITY DEFINER because public.activity has no INSERT grant to any role, and every one
-- ends at private.log_activity(), which owns the two rules they would otherwise each have
-- to remember: what counts as unread, and never notify somebody about their own act.
--
-- The interesting one is the last. **The moderation trigger fires on
-- public.moderation_actions rather than on the content tables**, which buys an invariant
-- worth more than the four triggers it replaces: there is exactly one audit row per
-- decision, so there is exactly one notification per decision. No logged decision goes
-- unannounced, and nothing announces a decision that was not logged. It also means
-- public.moderate() — 350 lines with a branch per target and a rule per action — is not
-- reissued to add this feature, and so cannot acquire a transcription error while doing it.
-- The audit row is written last inside that function, in the same transaction and after the
-- effect, so by the time this trigger runs the content row already says what happened.
--
-- What deliberately has no trigger: public.ratings on UPDATE (changing your score is not an
-- event anybody needs told), public.flags for the person flagged (see the enum comment in
-- the previous migration), and account erasure (there is nobody left to tell).

-- ── Reports ─────────────────────────────────────────────────────────────────────────

create function private.activity_on_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.log_activity(
      new.author_id, 'posted_report', new.author_id, 'report', new.id, null, new.title
    );
  else
    perform private.log_activity(
      new.author_id, 'edited_report', new.author_id, 'report', new.id, null, new.title
    );
  end if;

  return null;
end;
$$;

comment on function private.activity_on_report() is
  'Feed rows for posting and for editing a pending submission. Both are the author''s own '
  'acts, so neither counts as unread.';

revoke all on function private.activity_on_report() from public;

create trigger reports_activity_insert
  after insert on public.reports
  for each row
  execute function private.activity_on_report();

-- Editing is detected as content changing while the row is still pending, which is exactly
-- what public.resubmit_report() does and the only thing anybody may do — reports_update_own_pending
-- is the sole UPDATE policy on this table and it stops at publication. Watching a handful of
-- the long fields rather than every column keeps a moderator's note, a status change and the
-- updated_at touch from all reading as an edit by the author.
create trigger reports_activity_update
  after update on public.reports
  for each row
  when (
    new.status = 'pending'
    and new.deleted_at is null
    and (old.title, old.aim, old.method, old.outcome_notes, old.verification)
        is distinct from
        (new.title, new.aim, new.method, new.outcome_notes, new.verification)
  )
  execute function private.activity_on_report();

-- ── Debates ─────────────────────────────────────────────────────────────────────────

create function private.activity_on_debate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_activity(
    new.author_id, 'posted_debate', new.author_id, 'debate', new.id, null, new.statement
  );

  return null;
end;
$$;

revoke all on function private.activity_on_debate() from public;

create trigger debates_activity_insert
  after insert on public.debates
  for each row
  execute function private.activity_on_debate();

-- ── Network entries ─────────────────────────────────────────────────────────────────

create function private.activity_on_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_activity(
    new.submitter_id, 'posted_entry', new.submitter_id, 'entry', new.id, null, new.title
  );

  return null;
end;
$$;

revoke all on function private.activity_on_entry() from public;

create trigger network_entries_activity_insert
  after insert on public.network_entries
  for each row
  execute function private.activity_on_entry();

-- ── Comments ────────────────────────────────────────────────────────────────────────
-- One comment produces the author's own row, and at most one notification to somebody
-- else. Which one depends on where it sits:
--
--   a top-level comment  → the author of the report or debate is told;
--   a reply              → the author of the comment being replied to is told.
--
-- Not both, and this is the rule to hold on to rather than an optimisation. Threads here
-- are one level deep, so a reply to the content author's own comment would otherwise
-- produce two rows about one comment — and the alternative rule, telling the content author
-- about everything in their thread, makes a busy report unreadable for the one person least
-- able to stop reading it.
--
-- The target stays the report or debate in every case, because that is the page a link has
-- to open; comment_id carries the fragment to scroll to.

create function private.activity_on_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.moderation_target := private.as_target(new.parent_type);
  v_label  text := private.activity_label(v_target, new.parent_id);
  v_owner  uuid;
begin
  perform private.log_activity(
    new.author_id, 'commented', new.author_id, v_target, new.parent_id, new.id, v_label
  );

  if new.in_reply_to is not null then
    select c.author_id into v_owner
      from public.comments c
     where c.id = new.in_reply_to;

    perform private.log_activity(
      v_owner, 'comment_reply', new.author_id, v_target, new.parent_id, new.id, v_label
    );

    return null;
  end if;

  if new.parent_type = 'report' then
    select x.author_id into v_owner from public.reports x where x.id = new.parent_id;
  else
    select x.author_id into v_owner from public.debates x where x.id = new.parent_id;
  end if;

  perform private.log_activity(
    v_owner, 'content_commented', new.author_id, v_target, new.parent_id, new.id, v_label
  );

  return null;
end;
$$;

comment on function private.activity_on_comment() is
  'One own-action row, plus exactly one notification: to the replied-to comment''s author '
  'for a reply, or to the content''s author for a top-level comment.';

revoke all on function private.activity_on_comment() from public;

create trigger comments_activity_insert
  after insert on public.comments
  for each row
  execute function private.activity_on_comment();

-- ── Ratings ─────────────────────────────────────────────────────────────────────────
-- The debate's author is told that somebody rated, and is never told who: public.ratings is
-- readable only by its author, which is what stops a debate page revealing the aggregate
-- before you have taken a position, and a feed row naming the rater would hand back exactly
-- that. So the actor is null here on purpose — the reading layer says "somebody".
--
-- An explicit "no opinion" — a real row with a null score, which is how coverage is counted
-- — produces the rater's own log entry but no notification. It is a statement that the
-- question is outside somebody's expertise, and reporting it as a rating would inflate the
-- one number the agreement scale is careful to keep separate.

create function private.activity_on_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_label text;
begin
  select x.author_id, x.statement
    into v_owner, v_label
    from public.debates x
   where x.id = new.debate_id;

  perform private.log_activity(
    new.user_id, 'rated_debate', new.user_id, 'debate', new.debate_id, null, v_label
  );

  -- The "not your own act" test is made here rather than left to private.log_activity(),
  -- which cannot make it: that function compares the actor to the subject, and the actor
  -- passed below is null precisely so the row cannot name the rater. Without this line an
  -- author rating their own debate would be told that somebody rated it.
  if new.score is not null and v_owner is distinct from new.user_id then
    perform private.log_activity(
      v_owner, 'debate_rated', null, 'debate', new.debate_id, null, v_label
    );
  end if;

  return null;
end;
$$;

comment on function private.activity_on_rating() is
  'Tells a debate''s author that somebody rated it, and never which somebody. Inserts only: '
  'changing a score is not an event.';

revoke all on function private.activity_on_rating() from public;

create trigger ratings_activity_insert
  after insert on public.ratings
  for each row
  execute function private.activity_on_rating();

-- ── Report confirmations ────────────────────────────────────────────────────────────
-- A confirmation is public — it moves a tombstone on a listing — so the person who added it
-- is named here, unlike a rating.

create function private.activity_on_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_label text;
begin
  select x.author_id, x.title
    into v_owner, v_label
    from public.reports x
   where x.id = new.report_id;

  perform private.log_activity(
    new.user_id, 'confirmed_report', new.user_id, 'report', new.report_id, null, v_label
  );

  perform private.log_activity(
    v_owner, 'report_confirmed', new.user_id, 'report', new.report_id, null, v_label
  );

  return null;
end;
$$;

revoke all on function private.activity_on_confirmation() from public;

create trigger report_confirmations_activity_insert
  after insert on public.report_confirmations
  for each row
  execute function private.activity_on_confirmation();

-- ── Flags ───────────────────────────────────────────────────────────────────────────
-- The flagger's own row only. The person flagged is told nothing, now or ever: see the note
-- on public.activity_kind. The target is the flag rather than the content it names, so that
-- the resolution row written later by the moderation trigger lands on the same object.

create function private.activity_on_flag()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_activity(
    new.flagger_id,
    'flagged',
    new.flagger_id,
    'flag',
    new.id,
    null,
    private.activity_label(private.as_target(new.subject_type), new.subject_id)
  );

  return null;
end;
$$;

revoke all on function private.activity_on_flag() from public;

create trigger flags_activity_insert
  after insert on public.flags
  for each row
  execute function private.activity_on_flag();

-- ── Citations ───────────────────────────────────────────────────────────────────────
-- Both rows point at the *cited* piece rather than at the citing one. For the person who
-- made the citation that is where they were pointing; for the person cited it is their own
-- work, whose "referenced by" block already names what refers to it. Linking to the source
-- instead would be a link into content the reader may have no reason to be sent to, and
-- would need its heading copied into a label — which is the one thing the label column is
-- careful not to become.

create function private.activity_on_citation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.moderation_target := private.as_target(new.target_type);
  v_label  text := private.activity_label(v_target, new.target_id);
  v_owner  uuid;
begin
  perform private.log_activity(
    new.created_by, 'cited', new.created_by, v_target, new.target_id, null, v_label
  );

  if new.target_type = 'report' then
    select x.author_id into v_owner from public.reports x where x.id = new.target_id;
  else
    select x.author_id into v_owner from public.debates x where x.id = new.target_id;
  end if;

  perform private.log_activity(
    v_owner, 'content_cited', new.created_by, v_target, new.target_id, null, v_label
  );

  return null;
end;
$$;

revoke all on function private.activity_on_citation() from public;

create trigger citations_activity_insert
  after insert on public.citations
  for each row
  execute function private.activity_on_citation();

-- ── Moderation ──────────────────────────────────────────────────────────────────────
-- One audit row in, at most one notification out. See the header for why this hangs off the
-- log rather than off the four content tables.
--
-- **The actor is null in every branch, and that is the design rather than an oversight.**
-- The author is told what was decided about their work, never by whom. Naming the moderator
-- turns a hide into a grievance with an address on it, and it would undo, in a table the
-- moderated person can read, the reason public.moderation_actions is readable only by
-- moderators. What the moderated person is owed is the outcome, the note on their own
-- submission where one was written, and the appeals address in docs/moderation.md.
--
-- The reason text is never copied here either, for the same reason it is not shown on the
-- account page: it is written to another moderator in the shorthand of somebody who has read
-- the whole queue.

create function private.activity_on_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject    uuid;
  v_kind       public.activity_kind;
  v_target     public.moderation_target := new.target_type;
  v_target_id  uuid := new.target_id;
  v_comment_id uuid;
  v_label      text;
  v_parent     public.content_kind;
begin
  -- An erasure records that it happened and deliberately not whose, so there is no subject
  -- to find — and the account it was about is gone by the time this runs.
  if new.target_id is null then
    return null;
  end if;

  if new.target_type = 'report' then
    select x.author_id, x.title into v_subject, v_label
      from public.reports x where x.id = new.target_id;

    v_kind := case new.action
      when 'publish'         then 'report_published'
      when 'request_changes' then 'report_changes_requested'
      when 'hide'            then 'content_hidden'
      when 'unhide'          then 'content_unhidden'
    end;

  elsif new.target_type = 'debate' then
    select x.author_id, x.statement into v_subject, v_label
      from public.debates x where x.id = new.target_id;

    v_kind := case new.action
      when 'promote' then 'debate_promoted'
      when 'hide'    then 'content_hidden'
      when 'unhide'  then 'content_unhidden'
    end;

  elsif new.target_type = 'entry' then
    select x.submitter_id, x.title into v_subject, v_label
      from public.network_entries x where x.id = new.target_id;

    v_kind := case new.action
      when 'publish'         then 'entry_published'
      when 'request_changes' then 'entry_changes_requested'
      when 'hide'            then 'content_hidden'
      when 'unhide'          then 'content_unhidden'
    end;

  elsif new.target_type = 'comment' then
    -- The row moves to the thread the comment is in: target_type becomes the parent's, and
    -- the comment id rides along as the fragment. A link to a comment is a link to a page.
    select c.author_id, c.parent_type, c.parent_id
      into v_subject, v_parent, v_target_id
      from public.comments c where c.id = new.target_id;

    v_comment_id := new.target_id;
    v_target     := private.as_target(v_parent);
    v_label      := private.activity_label(v_target, v_target_id);

    v_kind := case new.action
      when 'hide'   then 'content_hidden'
      when 'unhide' then 'content_unhidden'
    end;

  elsif new.target_type = 'flag' then
    -- The flagger, not the flagged. This is the one branch whose subject is the person who
    -- asked for the decision rather than the person it was about.
    select f.flagger_id, private.activity_label(private.as_target(f.subject_type), f.subject_id)
      into v_subject, v_label
      from public.flags f where f.id = new.target_id;

    v_kind := case new.action
      when 'resolve_flag' then 'flag_resolved'
      when 'dismiss_flag' then 'flag_dismissed'
    end;

  elsif new.target_type = 'account' then
    v_subject := new.target_id;

    v_kind := case new.action
      when 'ban'   then 'account_banned'
      when 'unban' then 'account_unbanned'
    end;
  end if;

  -- An action with no notification attached to it — there is none today, but a value added
  -- to public.moderation_action later will land here rather than raise. A missing
  -- notification is the right failure for a log that has already recorded the decision:
  -- the audit row is the record, and this table is a courtesy.
  if v_kind is null then
    return null;
  end if;

  perform private.log_activity(
    v_subject, v_kind, null, v_target, v_target_id, v_comment_id, v_label
  );

  return null;
end;
$$;

comment on function private.activity_on_moderation() is
  'Turns each row of public.moderation_actions into at most one feed row for the person it '
  'was about. Never names the moderator and never copies the reason.';

revoke all on function private.activity_on_moderation() from public;

create trigger moderation_actions_activity_insert
  after insert on public.moderation_actions
  for each row
  execute function private.activity_on_moderation();
