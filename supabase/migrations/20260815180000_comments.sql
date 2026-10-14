-- public.comments — discussion attached to a practice or a proposition.
--
-- This is the first table on the site whose parent is polymorphic, and the first whose
-- rows are published without passing a moderator. Both are deliberate and both are
-- explained below, because both look like mistakes.
--
-- Why comments post immediately when practices do not
-- ---------------------------------------------------
-- A practice is a contribution to a corpus and waits for review. A comment is a reply, and
-- a reply that appears a day after the thing it replies to is not a reply. Moderation here
-- is reactive: the status column and the moderator hide policy are the same as everywhere
-- else, the default is just 'published' instead of 'pending'. Nothing ships without a
-- working hide path, and this has one.
--
-- Why the nesting stops at one level
-- ----------------------------------
-- Enforced in the database, not merely in the interface. Deep threads are how a discussion
-- becomes unreadable and unquotable: a claim four levels in has no stable address that
-- means anything, and the indentation makes a narrow screen useless. One level gives a
-- comment and the exchange under it, which is the shape of a referee's remark and the
-- author's answer. If you want to start a new line of argument, start a new comment.
--
-- Why deletion destroys the text
-- ------------------------------
-- Soft-delete keeps the node so the replies under it still make sense, and that is all it
-- keeps: the body goes to empty and the author goes to null, in a trigger, in the same
-- statement. The reader sees a marker rendered from `deleted_at` rather than stored prose,
-- so the marker never ends up in the export as though somebody had written it.
--
-- That is a real trade. A comment that was reported and then deleted cannot be read by the
-- moderator handling the report. The alternative is a table that retains text people asked
-- to have removed, which is the worse failure for a site whose privacy notice promises that
-- erasure actually works. Moderators who need the text intact should **hide** rather than
-- delete; hiding preserves everything and is what the moderator policy grants.
--
-- There is deliberately no `deleted_by` column, unlike public.practices. Recording the hand
-- that deleted a comment would re-attribute a row whose whole purpose is that attribution
-- was stripped — and only the author can delete one, so the column would carry exactly the
-- name the deletion removed.

-- The vocabulary for "which kind of thing is this attached to". One enum rather than one
-- per table, so that a comment's parent, a citation's endpoint and a report's subject are
-- described in the same words. 'comment' is a member because a report can be about a
-- comment; the two tables for which it makes no sense exclude it with a CHECK, which is a
-- cheaper thing to widen later than an enum is.
create type public.content_kind as enum ('practice', 'proposition', 'comment');

comment on type public.content_kind is
  'What a row points at. Restricted per table by CHECK: comments and citations accept only '
  'practice and proposition, reports accept all three.';

create table public.comments (
  id uuid primary key default gen_random_uuid(),

  -- No foreign key is possible on a polymorphic parent, so integrity comes from three
  -- other places instead: the CHECK below fixes the vocabulary, the insert policy requires
  -- the parent to exist *and be visible to the caller*, and the guard makes both columns
  -- immutable afterwards. Neither parent table has a DELETE grant or a DELETE policy, so
  -- there is no route by which a parent can vanish and leave this dangling.
  parent_type public.content_kind not null,
  parent_id   uuid not null,

  -- Nullable and SET NULL, as everywhere: erasure detaches rather than destroys, and the
  -- thread structure survives an account leaving.
  author_id uuid references public.profiles (id) on delete set null,

  -- One level only. A row whose in_reply_to points at a row that itself has one is refused
  -- by private.check_comment_thread(); see below for why that is a trigger and not a CHECK.
  in_reply_to uuid references public.comments (id) on delete cascade,

  body text not null,

  status public.content_status not null default 'published',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Set by the author; the trigger empties the body and strips the name in the same
  -- statement. See the header.
  deleted_at timestamptz,

  -- The length rule and the erasure rule in one constraint, so that a half-finished
  -- deletion is not representable. A live comment has a body; a deleted one has exactly
  -- the empty string, and no amount of later editing can put text back into it.
  constraint comments_body_length
    check (
      case
        when deleted_at is null then length(btrim(body)) between 1 and 5000
        else body = ''
      end
    ),

  -- The other half of deletion. Together with the trigger this means a deleted comment
  -- cannot carry a name, whatever route the update took.
  constraint comments_deleted_is_anonymous
    check (deleted_at is null or author_id is null),

  constraint comments_parent_kind
    check (parent_type in ('practice', 'proposition')),

  -- A comment cannot be its own reply. Cheap, and the kind of thing a script gets wrong.
  constraint comments_no_self_reply
    check (in_reply_to is distinct from id)
);

comment on table public.comments is
  'Discussion on a practice or a proposition. One level of nesting. Published on insert and '
  'moderated reactively; soft-delete empties the body and strips the author but keeps the '
  'node so replies still read.';
comment on column public.comments.parent_id is
  'No foreign key: the parent is polymorphic. Integrity comes from the insert policy, which '
  'requires a parent the caller can see, and from the guard, which freezes both columns.';
comment on column public.comments.deleted_at is
  'Author soft-delete. There is no deleted_by, because only the author can delete and '
  'recording the hand would restore the attribution the deletion removed.';

-- ── Indexes ─────────────────────────────────────────────────────────────────────────
-- The thread query is "every comment on this parent, oldest first" — oldest first because
-- a discussion is read in the order it happened, unlike a listing.

create index comments_thread_idx
  on public.comments (parent_type, parent_id, created_at)
  where status = 'published';

create index comments_reply_idx
  on public.comments (in_reply_to)
  where in_reply_to is not null;

create index comments_author_idx
  on public.comments (author_id)
  where author_id is not null;

-- The moderation queue for comments: reported ones are found through public.reports, but a
-- moderator also wants "everything hidden so far" to be cheap to look at.
create index comments_hidden_idx
  on public.comments (created_at desc)
  where status = 'hidden';

-- ── One level of nesting ────────────────────────────────────────────────────────────
-- A CHECK constraint cannot express this: it would have to read another row. So it is a
-- BEFORE INSERT trigger, and only INSERT, because the guard below makes in_reply_to
-- immutable and there is nothing left to check on update.
--
-- SECURITY INVOKER, and that is load-bearing rather than incidental. Running as the caller
-- means the lookup is subject to the same row level security as any other read, so a reply
-- to a hidden comment is refused for the same reason and by the same rule that stops the
-- caller reading it. The function asks "what shape is this thread", never "who is running
-- this", so the trap that makes a DEFINER guard useless does not apply either way.

create function private.check_comment_thread()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_reply  uuid;
  v_parent_type   public.content_kind;
  v_parent_parent uuid;
begin
  if new.in_reply_to is null then
    return new;
  end if;

  select c.in_reply_to, c.parent_type, c.parent_id
    into v_parent_reply, v_parent_type, v_parent_parent
    from public.comments c
   where c.id = new.in_reply_to;

  -- Deliberately the same message whether the comment never existed or is simply not
  -- readable by this caller. Distinguishing them would turn the endpoint into a way to
  -- probe for hidden content by id.
  if not found then
    raise exception 'That comment is not available to reply to.'
      using errcode = '23503';
  end if;

  if v_parent_reply is not null then
    raise exception
      'Replies go one level deep. Reply to the comment that started this exchange instead.'
      using errcode = '23514';
  end if;

  if v_parent_type is distinct from new.parent_type
     or v_parent_parent is distinct from new.parent_id then
    raise exception 'A reply belongs to the same discussion as the comment it answers.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

comment on function private.check_comment_thread() is
  'Enforces one level of nesting and that a reply stays in its own discussion. SECURITY '
  'INVOKER so the lookup obeys the caller''s row level security.';

revoke all on function private.check_comment_thread() from public;

create trigger comments_check_thread
  before insert on public.comments
  for each row
  execute function private.check_comment_thread();

-- ── The guard ───────────────────────────────────────────────────────────────────────
-- SECURITY INVOKER, for the reason recorded in CLAUDE.md and repeated in every guard on
-- this site: inside a DEFINER function current_user is the owner, so the trusted check
-- would pass on every browser request and the guard would revert nothing while reading in
-- review exactly like one that works.
--
-- **The edit window is enforced here rather than in a policy, and that is not a stylistic
-- choice.** Permissive row level security policies are OR'd together — both the USING
-- clauses and the WITH CHECK clauses. `comments_soft_delete_own` has to permit an update
-- at any age, because an author may delete a comment they wrote last year. Put the window
-- in `comments_update_own` and the delete policy grants exactly what the window withholds:
-- an ordinary edit passes the delete policy's USING (it is the author's, undeleted) and
-- then passes the edit policy's WITH CHECK. The window would be decorative. A trigger is
-- the only single choke point an update has.

create function private.protect_comment_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted   boolean;
  v_is_moderator boolean;
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

  v_is_moderator := exists (
    select 1
      from public.profiles p
     where p.id = (select auth.uid())
       and p.role in ('moderator', 'admin')
       and not p.is_banned
  );

  -- Immutable for absolutely everyone. Moving a comment to another discussion, or into
  -- another position in this one, would strand the replies under it.
  new.id          := old.id;
  new.parent_type := old.parent_type;
  new.parent_id   := old.parent_id;
  new.in_reply_to := old.in_reply_to;
  new.created_at  := old.created_at;

  if v_is_moderator then
    -- A moderator's whole power over a comment is `status`. Hiding preserves the text and
    -- the name, which is what makes it reviewable and reversible; editing somebody else's
    -- words under their name is not a moderation action in any tradition worth copying.
    new.author_id  := old.author_id;
    new.body       := old.body;
    new.deleted_at := old.deleted_at;
    return new;
  end if;

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

create trigger comments_protect_columns
  before update on public.comments
  for each row
  execute function private.protect_comment_columns();

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.comments enable row level security;

-- Published comments on a parent the caller can see. The parent clause is what stops a
-- discussion outliving the thing it is about: hide a practice and its thread stops being
-- readable through the API, without anything having to walk the comments and hide them
-- too. The subqueries run under the caller's own policies on those tables, so this
-- composes with them rather than restating them — an anonymous reader sees comments on
-- published practices, a moderator sees comments on everything.
--
-- Soft-deleted rows are included on purpose. The node has to remain or the replies under
-- it lose their sense, which is the whole point of soft deletion here.
create policy comments_select_visible
  on public.comments
  for select
  to anon, authenticated
  using (
    status = 'published'
    and (
      (parent_type = 'practice'
        and exists (select 1 from public.practices x where x.id = parent_id))
      or
      (parent_type = 'proposition'
        and exists (select 1 from public.propositions x where x.id = parent_id))
    )
  );

-- An author sees their own comment even after it has been hidden, so that being moderated
-- is something you can discover rather than something that silently happens to you.
create policy comments_select_own
  on public.comments
  for select
  to authenticated
  using (author_id = (select auth.uid()));

create policy comments_select_moderator
  on public.comments
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  );

-- The same three conditions as posting a practice — own name, confirmed address, not
-- banned — plus the two this table adds: it starts undeleted, and its parent has to be
-- something the caller can actually see.
create policy comments_insert_own
  on public.comments
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and status = 'published'
    and deleted_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
    and (
      (parent_type = 'practice'
        and exists (select 1 from public.practices x where x.id = parent_id))
      or
      (parent_type = 'proposition'
        and exists (select 1 from public.propositions x where x.id = parent_id))
    )
  );

-- Editing your own. The age limit is in the guard, not here; see the note on the guard for
-- why a policy cannot hold it.
create policy comments_update_own
  on public.comments
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and status = 'published'
    and deleted_at is null
  )
  with check (
    author_id = (select auth.uid())
    and deleted_at is null
  );

-- Deleting your own, at any age.
--
-- `author_id is null` in the WITH CHECK is not a typo and not a mistake. WITH CHECK is
-- evaluated against the row as the BEFORE triggers left it, and by then the guard has
-- already stripped the name. Requiring it here is what makes the policy *prove* the
-- stripping happened: if anybody ever removes that line from the guard, this policy starts
-- refusing deletions instead of quietly letting attributed ones through.
create policy comments_soft_delete_own
  on public.comments
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and deleted_at is null
  )
  with check (
    deleted_at is not null
    and author_id is null
  );

-- The hide path.
create policy comments_update_moderator
  on public.comments
  for update
  to authenticated
  using (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  )
  with check (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role in ('moderator', 'admin')
         and not p.is_banned
    )
  );

-- No DELETE policy and no DELETE grant. Removing the row would take its replies with it.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Nothing is auto-exposed in this project. Without these the table has no endpoint at all,
-- and a missing grant is indistinguishable from a missing policy when the client sees it.

grant select on public.comments to anon, authenticated;

-- `status` is absent, so a comment cannot be born hidden and the insert policy's
-- `status = 'published'` is a statement about the default rather than about user input.
grant insert (parent_type, parent_id, author_id, in_reply_to, body)
  on public.comments to authenticated;

-- `status` is present because moderators arrive as the same `authenticated` role as
-- everyone else and no column grant can tell them apart; the moderator policy and the
-- guard are what restrict it.
grant update (body, status, deleted_at) on public.comments to authenticated;
