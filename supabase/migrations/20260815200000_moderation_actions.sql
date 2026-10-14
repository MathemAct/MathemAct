-- public.moderation_actions — what was decided, by whom, and why.
--
-- The counterpart to public.reports. That table records what was *asked*; this one records
-- what was *done*. Volunteer moderation only holds together if both halves exist: a queue
-- with no log is a set of decisions nobody can review, and the people most likely to want
-- to review one are the moderators themselves, six months later, trying to remember whether
-- a rule was applied consistently.
--
-- Three properties, and every line below serves one of them.
--
-- 1. Append-only, including for the table owner.
--    No UPDATE and no DELETE, enforced by a trigger rather than only by absent grants,
--    because absent grants stop a browser and stop nothing else. A correction is a new row
--    saying what was corrected. Editing history to make a decision look better is the exact
--    failure an audit log exists to make impossible, and it is not a hypothetical: the
--    tempting case is a reason field with a typo in it, and the second tempting case is a
--    reason somebody wishes they had not written.
--
-- 2. Unforgeable.
--    There is no INSERT grant to any browser role. Rows arrive through public.moderate(),
--    which is SECURITY DEFINER and therefore writes as the table's owner. A moderator with
--    a console cannot write an audit row that describes something that did not happen, and
--    — because the same function performs the effect in the same transaction — cannot
--    perform something without writing the row either.
--
-- 3. Readable by moderators and admins, and by nobody else.
--    Not by the person who was moderated, and not by the person who reported them. Making
--    the log public would turn every hide into a public accusation with a name attached,
--    and the appeals path in docs/moderation.md is a private conversation on purpose.
--    What the moderated person gets instead is the note on their own submission and the
--    fact that they can see their own content's status.
--
-- What this table must never contain: an email address, or anything that would let one be
-- reconstructed. See the erasure note on the target_id constraint below, which is the one
-- place that rule bites.

-- ── The vocabularies ────────────────────────────────────────────────────────────────
-- Enums rather than text, for the same reason as everywhere else in this schema: these are
-- a fixed vocabulary rather than data, and a log containing both 'hide' and 'hidden' is a
-- log nobody can count.

create type public.moderation_target as enum (
  'practice',
  'proposition',
  'comment',
  -- A report is a target in its own right: resolving one is a decision about the report,
  -- separate from whatever was decided about the thing it named. Two decisions, two rows.
  'report',
  -- A person rather than a piece of content: a ban, or an erasure carried out on request.
  'account'
);

comment on type public.moderation_target is
  'What a moderation action was about. Wider than public.content_kind, which describes only '
  'things that can be commented on and cited.';

create type public.moderation_action as enum (
  -- Practices.
  'publish',
  'request_changes',
  -- Practices, propositions and comments.
  'hide',
  'unhide',
  -- Propositions.
  'promote',
  -- Reports. Two words rather than one, because "actioned" and "dismissed" are the two
  -- answers a reporter is eventually owed and they are not interchangeable.
  'resolve_report',
  'dismiss_report',
  -- Accounts.
  'ban',
  'unban',
  'erase_account'
);

comment on type public.moderation_action is
  'Every action the moderation screen offers. Adding a value here without adding a branch '
  'to public.moderate() produces a refusal rather than an unlogged action.';

-- ── The table ───────────────────────────────────────────────────────────────────────

create table public.moderation_actions (
  id uuid primary key default gen_random_uuid(),

  -- Nullable and ON DELETE SET NULL, like every other reference to a person on this site.
  -- A moderator who erases their account leaves the decisions standing without their name
  -- on them. That erasure is what the append-only trigger below has to make an exception
  -- for; it is the only exception.
  actor_id uuid references public.profiles (id) on delete set null,

  action      public.moderation_action not null,
  target_type public.moderation_target not null,

  -- No foreign key: the target is polymorphic, and one of the targets is deliberately not
  -- recorded at all. See the constraint below.
  target_id uuid,

  -- Required for the actions that take something away from somebody. Optional for the rest,
  -- because "published" needs no defence and a mandatory field produces "ok" a hundred
  -- times, which is worse than a blank.
  reason text,

  created_at timestamptz not null default now(),

  -- **The erasure exception.** An account erasure records that an erasure happened and
  -- refuses to record whose. Keeping the user id here would preserve, in a table designed
  -- never to be edited, precisely the fact somebody asked us to forget — and it would
  -- outlive the deletion_requests row, which cascades away with the account. So the row
  -- says: on this date, this admin, acting on a standing request, erased an account. That
  -- is what an auditor needs and it is the most that may be kept.
  constraint moderation_actions_target_recorded
    check ((target_id is null) = (action = 'erase_account')),

  constraint moderation_actions_reason_length
    check (reason is null or length(btrim(reason)) between 1 and 1000),

  -- Hiding something, telling an author to change it, and banning a person are the three
  -- actions somebody may later have to justify. The constraint is here as well as in
  -- public.moderate() because the function is the door and this is the wall.
  constraint moderation_actions_reason_required
    check (
      action not in ('hide', 'request_changes', 'ban')
      or (reason is not null and length(btrim(reason)) >= 1)
    )
);

comment on table public.moderation_actions is
  'Append-only log of moderation decisions. Written only by public.moderate(); readable '
  'only by moderators and admins. Contains no email address and, for an erasure, no user id.';
comment on column public.moderation_actions.target_id is
  'Null exactly for erase_account: the log records that an account was erased on request '
  'and deliberately does not record which one.';
comment on column public.moderation_actions.reason is
  'Shown to nobody but other moderators. Required for hide, request_changes and ban.';

-- The log is read one way in practice: newest first, and filtered to one target when
-- somebody asks "what has happened to this row".
create index moderation_actions_recent_idx
  on public.moderation_actions (created_at desc);

create index moderation_actions_target_idx
  on public.moderation_actions (target_type, target_id)
  where target_id is not null;

-- ── Append-only, for everyone ───────────────────────────────────────────────────────
-- This trigger fires for the table owner and for service_role as well as for a browser
-- role, which is unlike every other guard in this schema and is the point. Absent grants
-- protect the log from a moderator with a console; nothing but this protects it from a
-- migration written in a hurry.
--
-- To correct a row: add a new row. To genuinely remove one — a reason field that contains
-- something it should not — a migration must ALTER TABLE ... DISABLE TRIGGER explicitly,
-- which leaves the fact in the repository where it belongs.
--
-- The single exception is the foreign key above doing its own work. `ON DELETE SET NULL`
-- reaches this table as an UPDATE, so an account erasure would otherwise be blocked by the
-- log recording the erasures. The exception is written narrowly: actor_id going from
-- something to nothing, with every other column identical.

create function private.refuse_moderation_edit()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and old.actor_id is not null
     and new.actor_id is null
     and row(new.id, new.action, new.target_type, new.target_id, new.reason, new.created_at)
         is not distinct from
         row(old.id, old.action, old.target_type, old.target_id, old.reason, old.created_at)
  then
    -- An account being erased, taking the moderator's name off their decisions. The
    -- decisions stand; the hand goes.
    return new;
  end if;

  raise exception
    'The moderation log is append-only. Record a correction as a new action instead.'
    using errcode = '0A000';
end;
$$;

comment on function private.refuse_moderation_edit() is
  'Refuses every UPDATE and DELETE on public.moderation_actions except the actor_id being '
  'nulled by account erasure. Fires for the owner too, which is the point.';

revoke all on function private.refuse_moderation_edit() from public;

create trigger moderation_actions_append_only
  before update or delete on public.moderation_actions
  for each row
  execute function private.refuse_moderation_edit();

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.moderation_actions enable row level security;

-- The only policy on the table. There is no "read the actions taken on your own content"
-- policy, and that is a decision rather than an omission: the reason text is written to
-- another moderator, in the shorthand of people who have read the whole queue, and it is
-- not the explanation the moderated person is owed. They get the note on their submission
-- and, for anything more, the appeals address in docs/moderation.md.
create policy moderation_actions_select_moderator
  on public.moderation_actions
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

-- No INSERT, UPDATE or DELETE policy. Deliberate: rows come from public.moderate() running
-- as the owner, which policies do not apply to.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Nothing to anon, not even SELECT — the endpoint should not exist for a caller who could
-- never read a row through it. SELECT to authenticated, restricted to moderators by the
-- policy above.
--
-- No INSERT grant. This is the load-bearing line: it is what makes a forged audit row
-- impossible rather than merely refused, and it is why public.moderate() has to be
-- SECURITY DEFINER.

grant select on public.moderation_actions to authenticated;
