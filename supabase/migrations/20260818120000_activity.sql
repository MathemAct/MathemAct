-- public.activity — what each person did, and what happened to them because of it.
--
-- The site has never told anybody anything. A report is published and the author finds out
-- by looking; somebody comments on it and nobody is told at all. docs/moderation.md has
-- carried "No notification of any kind" in its honest list since the queue was built. This
-- is the answer to that, and it is deliberately not the answer that was rejected on
-- 2026-08-16 ("a message table is a second inbox nobody checks"). The difference matters,
-- so it is written down here rather than left to be rediscovered:
--
--   * A message table holds prose somebody had to write. This holds *events* — a kind, a
--     target, a timestamp — and the prose is composed in the reading layer from those three
--     things. Nobody writes a message, so there is no inbox to go stale.
--   * It is not a second place to look for a change request. reports.moderation_note is
--     still where the note itself lives and "Your submissions" is still where it is read.
--     An activity row says *that* changes were asked for and links there.
--
-- Why a table rather than deriving the feed from the corpus at read time. Three of the
-- events cannot be derived at all:
--
--   1. **When something was published.** public.reports has no published_at. Status is the
--      current state and carries no date, so "your report was published on the 14th" is
--      unrecoverable from the row.
--   2. **A moderation decision.** public.moderation_actions is readable by moderators and
--      by nobody else, on purpose — the reasons in it are written to other moderators. The
--      moderated person cannot read their own row and must not start being able to. This
--      table is the public-facing counterpart: the *outcome*, with no reason text and, by
--      design below, no moderator's name attached.
--   3. **A rating.** public.ratings is readable only by its author, which is what keeps the
--      aggregate hidden until somebody has rated. A debate's author cannot count the
--      ratings on their own debate and should not be able to.
--
-- Two properties this table shares with the moderation log, for the same reasons:
--
--   * **Unforgeable.** No INSERT grant to any browser role. Rows arrive from the DEFINER
--     trigger functions below. An account cannot manufacture a notification, which matters
--     because a notification is a thing people believe.
--   * **Contains no address and no private text.** The `label` column holds the title of a
--     report or the statement of a debate — content the subject either wrote or can already
--     read. It never holds a comment body, a flag's detail, or a moderator's reason. See the
--     note on the column.
--
-- What it is NOT: an audit log. Rows here are a convenience for one person and are deleted
-- with that person's account. The record of what was decided is public.moderation_actions,
-- which outlives the accounts on both ends of it.

-- ── The vocabulary ──────────────────────────────────────────────────────────────────
-- Two halves, and which half a value belongs to is the load-bearing distinction in this
-- file. An event is either something the subject *did*, which is a log entry they already
-- know about, or something that *happened to them*, which is a notification and counts as
-- unread. Mixing them produces a badge that lights up because you posted, which trains
-- people to ignore it.
--
-- private.log_activity() below classifies every value with a CASE that has no ELSE, so
-- adding a value here without deciding which half it is in raises rather than guessing.

create type public.activity_kind as enum (
  -- ── Things you did ────────────────────────────────────────────────────────────────
  'posted_report',
  'edited_report',
  'posted_debate',
  'posted_entry',
  'commented',
  'rated_debate',
  'confirmed_report',
  'flagged',
  'cited',

  -- ── Things that happened to you ───────────────────────────────────────────────────
  -- Moderation outcomes. One per decision the subject is owed, and no more: there is no
  -- value here for a flag being *filed* against your content, which is deliberate. Telling
  -- an author they have been flagged invites them to work out by whom, and the appeals
  -- path in docs/moderation.md is a private conversation on purpose.
  'report_published',
  'report_changes_requested',
  'entry_published',
  'entry_changes_requested',
  'debate_promoted',
  -- Hidden and unhidden cover all four content types; target_type says which.
  'content_hidden',
  'content_unhidden',
  'account_banned',
  'account_unbanned',
  -- The two answers a flagger is eventually owed, in the same two words the log uses.
  'flag_resolved',
  'flag_dismissed',

  -- Other people.
  'content_commented',
  'comment_reply',
  'debate_rated',
  'report_confirmed',
  'content_cited'
);

comment on type public.activity_kind is
  'Every event that can appear in an activity feed. Adding a value requires a branch in '
  'the is_inbound CASE inside private.log_activity(), which has no ELSE.';

-- ── The table ───────────────────────────────────────────────────────────────────────

create table public.activity (
  id uuid primary key default gen_random_uuid(),

  -- Whose feed this row is in. CASCADE rather than SET NULL, unlike every other reference
  -- to a person in this schema: a feed with no subject is not a contribution that should
  -- outlive the account, it is a pile of notifications addressed to nobody.
  subject_id uuid not null references public.profiles (id) on delete cascade,

  kind public.activity_kind not null,

  -- Whether this counts as unread. Derived from `kind` by private.log_activity(), which is
  -- the only writer — there is no INSERT grant to anybody, which is what makes "the only
  -- writer" a fact rather than a convention.
  --
  -- Not a generated column, and that is a version decision rather than a preference:
  -- ALTER COLUMN ... SET EXPRESSION arrived in Postgres 17, so on 15 a change to the
  -- classification would mean dropping and re-adding the column and rewriting the table.
  is_inbound boolean not null,

  -- Who did it, where naming them is right. Null in three cases, each on purpose:
  --
  --   * every moderation outcome — the author is told what was decided, not who decided
  --     it. A name here turns a hide into a personal grievance, and the moderation log is
  --     private for the same reason;
  --   * every rating — public.ratings is readable only by its author, and a row here
  --     naming the rater would leak exactly what that policy protects;
  --   * an erased account, by the SET NULL below, which reads as "somebody".
  actor_id uuid references public.profiles (id) on delete set null,

  -- Polymorphic, so no foreign key — the same shape as public.citations and
  -- public.moderation_actions, and it reuses the latter's enum rather than declaring a
  -- second copy of the same six words. The mapping from a moderation decision to an
  -- activity row is then the identity on this column, which is one fewer place to drift.
  target_type public.moderation_target not null,
  target_id   uuid not null,

  -- Set when the event is about a comment, so the link can carry a fragment to it. The
  -- target above stays the report or debate the thread is on, because that is the page
  -- that has to load either way.
  comment_id uuid references public.comments (id) on delete set null,

  -- The title of the report, the statement of the debate, or the name of the entry the
  -- event happened on — enough for the feed to read as prose rather than as "a report".
  --
  -- Denormalised on purpose, and the rule about *what* may be copied here is the whole of
  -- its safety. It is always the heading of the thing the event is *on*, which the subject
  -- either wrote or can already read. It is never a comment body, never a flag's detail,
  -- never a moderator's reason. Copying one of those would republish, in a row nobody
  -- moderates, exactly the text a moderator might later hide.
  label text,

  created_at timestamptz not null default now(),

  constraint activity_label_length
    check (label is null or length(btrim(label)) between 1 and 200),

  -- A comment id belongs only to the events that are about a comment. Stated as a
  -- constraint because the alternative is a link with a dangling fragment, which looks
  -- like a broken page rather than like a bad row.
  constraint activity_comment_id_relevant
    check (
      comment_id is null
      or kind in ('commented', 'content_commented', 'comment_reply', 'content_hidden',
                  'content_unhidden')
    )
);

comment on table public.activity is
  'Per-person activity feed: what somebody did, and what happened to their contributions. '
  'Written only by the DEFINER triggers in this migration; readable only by its subject. '
  'Never exported.';
comment on column public.activity.is_inbound is
  'True for events caused by somebody else, which are notifications and count as unread. '
  'False for the subject''s own actions, which are a log they already know about.';
comment on column public.activity.actor_id is
  'Null for every moderation outcome and every rating, deliberately. See the migration.';
comment on column public.activity.label is
  'Heading of the report, debate or entry the event is about. Never a comment body, a '
  'flag detail, or a moderation reason.';

-- The feed is read one way — one person's rows, newest first — and the unread count reads
-- the same thing filtered. The partial index carries the filter so the count does not walk
-- a long log of the subject's own actions to find three notifications.
create index activity_subject_idx
  on public.activity (subject_id, created_at desc);

create index activity_inbound_idx
  on public.activity (subject_id, created_at desc)
  where is_inbound;

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.activity enable row level security;

-- The only policy. Your own feed and nobody else's — not a moderator's, either. There is
-- nothing here a moderator needs that public.moderation_actions does not already hold, and
-- a queue screen that could read anyone's notifications would be a way to watch a person.
create policy activity_select_own
  on public.activity
  for select
  to authenticated
  using (subject_id = (select auth.uid()));

-- No INSERT, UPDATE or DELETE policy. Rows come from the trigger functions below, running
-- as the table's owner, which policies do not apply to. A subject cannot delete a
-- notification either; the watermark below is how a feed is dismissed.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Nothing at all to anon: the endpoint should not exist for a caller who could never read
-- a row through it. No INSERT grant to anybody, which is the load-bearing line — it is
-- what makes a forged notification impossible rather than merely refused.

grant select on public.activity to authenticated;

-- ── The watermark ───────────────────────────────────────────────────────────────────
-- One timestamp per person: when they last looked. Everything inbound after it is new.
--
-- A watermark rather than a read flag per row, for two reasons. It needs no UPDATE grant
-- on public.activity, so that table stays append-only from every browser's point of view.
-- And "you have looked at your notifications" is one fact, so storing it once means it
-- cannot be half true.
--
-- This is the one table in the feature the browser writes to, and it is the person's own
-- data in the fullest sense: the worst they can do with it is decide their own
-- notifications are read, or decide they are not.

create table public.activity_seen (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  seen_at timestamptz not null default now()
);

comment on table public.activity_seen is
  'When each person last looked at their activity feed. Anything inbound after this is '
  'shown as new. Written by the browser; one row per person, their own.';

alter table public.activity_seen enable row level security;

create policy activity_seen_select_own
  on public.activity_seen
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy activity_seen_insert_own
  on public.activity_seen
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy activity_seen_update_own
  on public.activity_seen
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- INSERT and UPDATE both, because the browser writes this with a single upsert and
-- PostgREST needs the privilege for either branch of it. UPDATE covers user_id as well as
-- seen_at for the same reason — an upsert's ON CONFLICT clause assigns every column in the
-- payload — and the policy above is what keeps the row the caller's own.
grant select, insert, update (user_id, seen_at) on public.activity_seen to authenticated;

-- ── Writing a row ───────────────────────────────────────────────────────────────────
-- Every trigger in this file goes through here, so the three rules that make the feed
-- trustworthy are stated once.
--
-- SECURITY DEFINER, and this is the safe direction of the trap in CLAUDE.md rather than an
-- instance of it. The trap is a *guard* that asks `current_user`, which inside a DEFINER
-- function is the owner and therefore always trusted. Nothing here asks who is running the
-- statement: the subject and the actor both arrive as arguments taken from row data the
-- trigger was handed. DEFINER is needed for one reason only — public.activity has no
-- INSERT grant to any role, including the one whose statement fired the trigger.

create function private.log_activity(
  p_subject     uuid,
  p_kind        public.activity_kind,
  p_actor       uuid,
  p_target_type public.moderation_target,
  p_target_id   uuid,
  p_comment_id  uuid default null,
  p_label       text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inbound boolean;
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

  insert into public.activity (
    subject_id, kind, is_inbound, actor_id, target_type, target_id, comment_id, label
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
    nullif(left(btrim(coalesce(p_label, '')), 200), '')
  );
end;
$$;

comment on function private.log_activity(uuid, public.activity_kind, uuid,
                                         public.moderation_target, uuid, uuid, text) is
  'The only writer of public.activity. Classifies the kind, refuses to notify somebody '
  'about their own act, and truncates the label.';

-- Postgres grants EXECUTE to PUBLIC on every new function, so each one here needs this.
-- .github/workflows/migrate.yml asserts in production that nothing in the private schema
-- is reachable by a browser role.
revoke all on function private.log_activity(uuid, public.activity_kind, uuid,
                                            public.moderation_target, uuid, uuid, text)
  from public;

-- public.content_kind widened to public.moderation_target: the three words a comment or a
-- flag can point at, in the six-word vocabulary this table uses. Written as a mapping rather
-- than a cast, so that the day one enum gains a label the other does not, this stops
-- compiling instead of silently resolving to the wrong one.
create function private.as_target(p_kind public.content_kind)
returns public.moderation_target
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_kind
    when 'report'  then 'report'::public.moderation_target
    when 'debate'  then 'debate'::public.moderation_target
    when 'comment' then 'comment'::public.moderation_target
  end;
$$;

comment on function private.as_target(public.content_kind) is
  'public.content_kind widened to public.moderation_target, by name rather than by cast.';

revoke all on function private.as_target(public.content_kind) from public;

-- The heading of a report, debate or entry, for the label column. Returns null for anything
-- else, including a target that has since gone.
--
-- A comment resolves to the heading of the thread it is in, never to its own body. That is
-- the rule on the label column doing its work at the one place it could plausibly be broken:
-- a flag may point at a comment, and "you flagged" wants something to name.
create function private.activity_label(
  p_type public.moderation_target,
  p_id   uuid
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_label  text;
  v_parent public.content_kind;
  v_id     uuid := p_id;
  v_type   public.moderation_target := p_type;
begin
  if v_type = 'comment' then
    select c.parent_type, c.parent_id
      into v_parent, v_id
      from public.comments c
     where c.id = p_id;

    if v_parent is null then
      return null;
    end if;

    v_type := private.as_target(v_parent);
  end if;

  if v_type = 'report' then
    select x.title into v_label from public.reports x where x.id = v_id;
  elsif v_type = 'debate' then
    select x.statement into v_label from public.debates x where x.id = v_id;
  elsif v_type = 'entry' then
    select x.title into v_label from public.network_entries x where x.id = v_id;
  end if;

  return v_label;
end;
$$;

comment on function private.activity_label(public.moderation_target, uuid) is
  'The heading of a report, debate or entry, and for a comment the heading of the thread it '
  'is in. Never a comment body — see the note on public.activity.label.';

revoke all on function private.activity_label(public.moderation_target, uuid) from public;
