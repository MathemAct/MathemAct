-- Moderation stops being a gate and becomes an answer to a flag.
--
-- Until now every report and every network entry was born `pending` and stayed invisible
-- until a volunteer moderator published it, and every debate was born `proposed` and was
-- not part of the record until somebody promoted it. That is pre-moderation, and it has
-- three costs this project cannot pay:
--
--   * **It puts a volunteer between a mathematician and the corpus.** The single most
--     important flow in CLAUDE.md is a researcher submitting a well-structured account in
--     under ten minutes. A queue worked "carefully and slowly" turns that ten minutes into
--     an unknown number of days, and the person who waits is the person who never comes
--     back.
--   * **It scales with submissions rather than with problems.** Two volunteers reading
--     everything is a corpus capped at what two people can read.
--   * **It reads as approval.** A corpus where every account passed a moderator implies the
--     moderators vouched for the mathematics. They did not, they cannot, and the whole
--     positioning in CLAUDE.md — a reporting layer, not a journal — depends on nobody
--     thinking they did.
--
-- What replaces it: **content is published when it is posted, and moderators decide flags.**
-- A moderator's work starts when a reader says something is wrong with a post. The decision
-- is one of two — hide it, or leave it up — and either way it carries an explanation that
-- the author of the content and the person who flagged it both read. That last part is new:
-- until today the only written reason lived in public.moderation_actions, which is readable
-- by moderators and by nobody else, on purpose, because it is written to other moderators.
--
-- So this migration does five things:
--
--   1. Everything is born published. The status columns keep `pending`, which nothing
--      enters any more; the enum is not narrowed, because the audit log and two backfilled
--      feeds still refer to a world where it existed.
--   2. A report is editable by its author while it is hidden — which is what makes a hide
--      the start of a conversation rather than a wall — and until somebody else has
--      confirmed or commented on it. That second half restates the rule the old freeze was
--      a proxy for: confirmations attest to a version, so the text fixes itself the moment
--      one exists, and not a second before.
--   3. The change-request columns go. `request_changes` was their only writer and there is
--      no longer a state for a submission to be sent back to.
--   4. public.moderation_notices arrives — the decision, written once and addressed to the
--      people it is about. One row per recipient, so the policy protecting it is
--      `recipient_id = auth.uid()` and nothing more delicate than that.
--   5. public.moderate() is reissued around the new rule: every decision needs an
--      explanation, hiding something closes the flags that named it, and the three actions
--      that belonged to the gate — publish, request_changes, promote — refuse.
--
-- What does not change, and is worth saying because it is the part people assume moves:
-- there is still exactly one audited door. public.moderate() is still the only route, the
-- log is still append-only, and there are still no moderator UPDATE policies on any content
-- table. Post-moderation changes *when* somebody decides, not whether the decision is
-- recorded.

-- ── 1. Everything is born published ─────────────────────────────────────────────────
-- The column default does the work, not the policy: `status` has no INSERT column grant on
-- any of these tables, so a browser cannot name it in either direction and the default is
-- the only value it can take. The policies below are rewritten to agree with the new
-- default rather than to enforce it — a WITH CHECK still saying `pending` would refuse
-- every insert on the site.

alter table public.reports         alter column status set default 'published';
alter table public.network_entries alter column status set default 'published';

-- A debate is born part of the record. debates_activated_iff_active ties the date to the
-- status, so both defaults move together or the first insert fails the check.
alter table public.debates alter column status       set default 'active';
alter table public.debates alter column activated_at set default now();

drop policy reports_insert_own on public.reports;

create policy reports_insert_own
  on public.reports
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
  );

drop policy network_entries_insert_own on public.network_entries;

create policy network_entries_insert_own
  on public.network_entries
  for insert
  to authenticated
  with check (
    submitter_id = (select auth.uid())
    and status = 'published'
    and deleted_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

drop policy debates_insert_own on public.debates;

create policy debates_insert_own
  on public.debates
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and status = 'active'
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

-- Anything already waiting is published now rather than left in a state nothing can leave.
-- These run as the table owner, so the guard triggers pass them through untouched, and no
-- activity trigger watches a status change on a content table — nobody is told by a
-- migration that their year-old submission has just been "published".
update public.reports
   set status = 'published'
 where status = 'pending'
   and deleted_at is null;

update public.network_entries
   set status = 'published'
 where status = 'pending'
   and deleted_at is null;

-- coalesce, not now(): a claim that has been rated for a week joined the record when it was
-- posted, and dating it today would put it at the top of a list ordered by activation.
update public.debates
   set status = 'active', activated_at = coalesce(activated_at, created_at)
 where status = 'proposed';

-- The queue indexes described a queue that no longer exists. What a moderator now has to
-- find quickly is the hidden set, which is the only content-shaped list left on the screen.
drop index if exists public.reports_pending_idx;
drop index if exists public.reports_awaiting_author_idx;
drop index if exists public.network_entries_pending_idx;
drop index if exists public.network_entries_awaiting_author_idx;
drop index if exists public.debates_proposed_idx;

create index reports_hidden_idx
  on public.reports (created_at desc)
  where status = 'hidden' and deleted_at is null;

create index network_entries_hidden_idx
  on public.network_entries (created_at desc)
  where status = 'hidden' and deleted_at is null;

create index debates_hidden_idx
  on public.debates (created_at desc)
  where status = 'hidden';

-- ── 2. What an author may still edit ────────────────────────────────────────────────
-- The old rule was "editable while pending", which was a window between submitting and
-- being read. There is no such window any more, so the rule has to be restated — and
-- restating it as "editable while hidden" would be wrong in a way that only shows up in the
-- one flow this project cares most about.
--
-- **A report is editable while it is hidden, or until somebody else has responded to it.**
-- A response is a confirmation or a comment. Three things fall out of that sentence, and
-- each one is why it is written this way rather than more simply:
--
--   * **Publishing is instant, so freezing at publication would freeze at the keystroke.**
--     A typo in a title would be permanent one second after it was made. The old pending
--     state was an accidental edit window and it is worth keeping deliberately.
--   * **The reason the text freezes at all is other people.** "Still works / no longer
--     works" confirmations attest to a version, and a comment quotes one. Until either
--     exists there is nothing pointing at the old text, so nothing is misled by a change.
--     This is the rule that was always meant; "at publication" was a proxy for it that
--     stopped being a good one the day publication stopped being a decision.
--   * **public.submit_report() would otherwise be broken.** It is SECURITY INVOKER and
--     inserts the tools and tags immediately after the report, under the caller's own
--     policies. Those policies gate on the parent, so a rule of "hidden only" would refuse
--     every tool row on every new submission — the deferred at-least-one-tool constraint
--     would then fail the transaction, and posting a report would stop working entirely.
--
-- The predicate is written out in each policy rather than factored into a function on
-- purpose: a browser role has no USAGE on the private schema, so a policy that called a
-- helper there would fail with a permission error rather than a refusal. Everything below
-- says the same thing four times, which is the shape this schema already has.

drop policy reports_update_own_pending on public.reports;

create policy reports_update_own_editable
  on public.reports
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and deleted_at is null
    and (
      status = 'hidden'
      or (
        not exists (
          select 1 from public.report_confirmations c where c.report_id = reports.id
        )
        and not exists (
          select 1
            from public.comments m
           where m.parent_type = 'report'
             and m.parent_id = reports.id
        )
      )
    )
  )
  with check (
    author_id = (select auth.uid())
    and (
      status = 'hidden'
      or (
        not exists (
          select 1 from public.report_confirmations c where c.report_id = reports.id
        )
        and not exists (
          select 1
            from public.comments m
           where m.parent_type = 'report'
             and m.parent_id = reports.id
        )
      )
    )
  );

-- The tools and the tags follow the report, which is what they have always done — only the
-- condition they defer to has changed. Written as five policies rather than one because
-- each command needs its own, and dropped by their old names, which still say `pending`.

drop policy report_tools_insert_own_pending on public.report_tools;
drop policy report_tools_update_own_pending on public.report_tools;
drop policy report_tools_delete_own_pending on public.report_tools;
drop policy report_tags_insert_own_pending  on public.report_tags;
drop policy report_tags_delete_own_pending  on public.report_tags;

create policy report_tools_insert_own_editable
  on public.report_tools
  for insert
  to authenticated
  with check (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (
           p.status = 'hidden'
           or (
             not exists (
               select 1 from public.report_confirmations c where c.report_id = p.id
             )
             and not exists (
               select 1
                 from public.comments m
                where m.parent_type = 'report'
                  and m.parent_id = p.id
             )
           )
         )
    )
  );

create policy report_tools_update_own_editable
  on public.report_tools
  for update
  to authenticated
  using (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (
           p.status = 'hidden'
           or (
             not exists (
               select 1 from public.report_confirmations c where c.report_id = p.id
             )
             and not exists (
               select 1
                 from public.comments m
                where m.parent_type = 'report'
                  and m.parent_id = p.id
             )
           )
         )
    )
  )
  with check (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (
           p.status = 'hidden'
           or (
             not exists (
               select 1 from public.report_confirmations c where c.report_id = p.id
             )
             and not exists (
               select 1
                 from public.comments m
                where m.parent_type = 'report'
                  and m.parent_id = p.id
             )
           )
         )
    )
  );

-- Deleting a tool row is editing, not deleting content, which is why it is allowed here
-- while reports themselves have no DELETE policy at all. The at-least-one trigger still
-- applies, so the last one cannot go.
create policy report_tools_delete_own_editable
  on public.report_tools
  for delete
  to authenticated
  using (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (
           p.status = 'hidden'
           or (
             not exists (
               select 1 from public.report_confirmations c where c.report_id = p.id
             )
             and not exists (
               select 1
                 from public.comments m
                where m.parent_type = 'report'
                  and m.parent_id = p.id
             )
           )
         )
    )
  );

create policy report_tags_insert_own_editable
  on public.report_tags
  for insert
  to authenticated
  with check (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (
           p.status = 'hidden'
           or (
             not exists (
               select 1 from public.report_confirmations c where c.report_id = p.id
             )
             and not exists (
               select 1
                 from public.comments m
                where m.parent_type = 'report'
                  and m.parent_id = p.id
             )
           )
         )
    )
    -- A retired tag cannot be added to new work, while reports already carrying it keep
    -- resolving. That is the whole reason is_active exists.
    and exists (
      select 1 from public.tags t where t.id = tag_id and t.is_active
    )
  );

create policy report_tags_delete_own_editable
  on public.report_tags
  for delete
  to authenticated
  using (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (
           p.status = 'hidden'
           or (
             not exists (
               select 1 from public.report_confirmations c where c.report_id = p.id
             )
             and not exists (
               select 1
                 from public.comments m
                where m.parent_type = 'report'
                  and m.parent_id = p.id
             )
           )
         )
    )
  );

-- A network entry has no confirmations and no comments, so there is nothing for it to
-- freeze against and the simpler rule is the honest one: its submitter may edit it while it
-- is hidden, which is what makes a hide answerable. Everything else about it is one link and
-- two paragraphs, and correcting those after publication is what the flag queue is for.
drop policy network_entries_update_own_pending on public.network_entries;

create policy network_entries_update_own_hidden
  on public.network_entries
  for update
  to authenticated
  using (
    submitter_id = (select auth.uid())
    and status = 'hidden'
    and deleted_at is null
  )
  with check (
    submitter_id = (select auth.uid())
    and status = 'hidden'
  );

-- A debate never had a pending state, but its policy named the proposed one it no longer
-- reaches. The wording of a rated claim is frozen by the guard trigger rather than by this
-- policy — people agreed with the sentence in front of them — so the policy only has to say
-- whose row it is.
drop policy debates_update_own on public.debates;

create policy debates_update_own
  on public.debates
  for update
  to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));

-- ── 3. The change-request columns go ────────────────────────────────────────────────
-- public.moderate()'s `request_changes` branch was their only writer, and there is no state
-- for a submission to be sent back to. What replaces them is public.moderation_notices
-- below, which is not the same thing wearing a new name: a note lived on a row and said
-- what to change, a notice is addressed to a person and says what was decided and why.
--
-- The two CHECK constraints and the awaiting-author index go with the columns, which is
-- what DROP COLUMN does by itself.

alter table public.reports
  drop column moderation_note,
  drop column moderation_note_at,
  drop column moderation_note_by;

alter table public.network_entries
  drop column moderation_note,
  drop column moderation_note_at,
  drop column moderation_note_by;

-- Both guards named those columns, and a plpgsql body is stored as text — it would have
-- kept compiling and failed at the first UPDATE. Reissued in full, with the freeze rule
-- moved from "past pending" to "anything but hidden".

create or replace function private.protect_report_columns()
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
           where c.oid = 'public.reports'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for everyone. Reassigning an author would move a contribution onto somebody
  -- else's name, which is the one thing a corpus under CC BY must never do.
  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  -- Status is nobody's to set from a browser. There is no moderator policy on this table
  -- and there will not be one again: public.moderate() is the only way into hidden or out
  -- of it, which is what keeps every such move in the log.
  new.status := old.status;

  -- Restoring a deleted report is a moderation action, not an authoring one. Without this,
  -- "delete" would be a toggle and a soft-deleted row could be brought back after the
  -- discussion around it had moved on.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- **The text is fixed once somebody else has responded to it, and unfixed again while it
  -- is hidden.** An account that can be rewritten after people have confirmed it still works
  -- is not a record of anything — the confirmations would attest to a version nobody can
  -- read. Until anybody has confirmed or commented there is nothing pointing at the old
  -- text, so a correction misleads nobody; and hidden content is off the site with its
  -- author holding a written reason, which is exactly when rewriting it is the point.
  --
  -- The same condition is in reports_update_own_editable, which is what actually refuses the
  -- statement. This is the second lock, and it is the one that decides *columns* — an author
  -- whose report is still editable may change the text and still may not touch `status`.
  if old.status <> 'hidden'
     and (
       exists (
         select 1 from public.report_confirmations c where c.report_id = old.id
       )
       or exists (
         select 1
           from public.comments m
          where m.parent_type = 'report'
            and m.parent_id = old.id
       )
     )
  then
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

comment on function private.protect_report_columns() is
  'Reverts writes to columns the caller does not own. Text is editable while the report is '
  'hidden, and until somebody else has confirmed or commented on it. Deliberately SECURITY '
  'INVOKER: as DEFINER, current_user would always be the owner and the guard would never fire.';

create or replace function private.protect_network_columns()
returns trigger
language plpgsql
security invoker        -- must remain INVOKER: the current_user check decides who is trusted
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  -- url_normalised was already set by normalise_network_url(), which fires before this
  -- trigger (alphabetical: network_entries_a_ before network_entries_b_).
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.network_entries'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for everyone.
  new.id           := old.id;
  new.submitter_id := old.submitter_id;
  new.created_at   := old.created_at;

  -- Status is public.moderate()'s; the link columns are the link-check script's. No browser
  -- caller may write either.
  new.status          := old.status;
  new.link_status     := old.link_status;
  new.link_checked_at := old.link_checked_at;

  -- Restoring a deleted entry is a moderation action.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- Hidden is the editable state, exactly as on reports.
  if old.status <> 'hidden' then
    new.title          := old.title;
    new.url            := old.url;
    new.url_normalised := old.url_normalised;
    new.category       := old.category;
    new.description    := old.description;
    new.relevance      := old.relevance;
  end if;

  return new;
end;
$$;

comment on function private.protect_network_columns() is
  'Reverts writes to columns the caller does not own. Text is editable only while the entry '
  'is hidden. SECURITY INVOKER for the same reason as every other guard here.';

-- ── 4. The decision, written to the people it is about ──────────────────────────────
-- public.moderation_notices is the answer to the question this whole change turns on: if a
-- moderator hides something, who is owed an explanation, and where do they read it?
--
-- Two people are owed one — the author of the content and whoever flagged it — and neither
-- of them may read public.moderation_actions. That is not an oversight to be relaxed now
-- that reasons matter more: the log is written *to other moderators*, in the shorthand of
-- people who have read the whole queue, and it names the moderator. A notice is written to
-- a member, is the same sentence the log keeps, and names nobody.
--
-- **One row per recipient.** The alternative — one row per decision, with a policy asking
-- "are you the author of the thing this points at, or did you flag it?" — needs a
-- polymorphic join inside a USING clause, evaluated per row, over four content tables. This
-- shape makes the policy `recipient_id = (select auth.uid())`, which is the same one-line
-- rule as public.activity and is checkable by reading it.
--
-- What a notice may contain: the outcome, the explanation, and a label naming the content.
-- What it may not: an address, the moderator's name, or the flagger's. A notice tells you
-- what was decided about a post and why. Who asked for the decision is not part of the
-- answer, and telling an author who flagged them is how a moderation system becomes a
-- weapon.

create type public.moderation_outcome as enum (
  -- The content is off the site. Its author can still read it, and edit it.
  'hidden',
  -- A flag was looked at and the content stays up. The one decision that has to be
  -- reportable as its own thing: "we did nothing" is an answer, and a silent queue is how
  -- people learn that flagging does nothing.
  'kept',
  -- Hidden content is back.
  'restored'
);

comment on type public.moderation_outcome is
  'What a moderation decision did, in the words a member reads. Not the same vocabulary as '
  'public.moderation_action, which is the moderator''s.';

create type public.notice_recipient as enum ('author', 'flagger');

comment on type public.notice_recipient is
  'Why this person is being told. The same decision reaches an author and a flagger as two '
  'rows, and each reads differently on the page.';

create table public.moderation_notices (
  id uuid primary key default gen_random_uuid(),

  -- The audit row this notice reports. No ON DELETE clause, because there is no delete:
  -- public.moderation_actions refuses one by trigger, for the owner too.
  action_id uuid not null references public.moderation_actions (id),

  -- What the decision was about. Polymorphic like every other pointer at content here, so
  -- no foreign key; the CHECK keeps it to the four things that can be moderated as content.
  subject_type public.moderation_target not null,
  subject_id   uuid not null,

  -- The heading of the report, debate or entry — and for a comment, the heading of the
  -- thread it is in, never the comment body. private.activity_label() decides, so this
  -- column and public.activity.label cannot drift apart.
  label text,

  outcome     public.moderation_outcome not null,
  explanation text not null,

  -- CASCADE, like public.activity and unlike everything else in this schema. A notice is a
  -- message to one person, not a contribution: when the account goes, the message addressed
  -- to it goes too. The decision itself survives in the log, which is the record.
  recipient_id   uuid not null references public.profiles (id) on delete cascade,
  recipient_role public.notice_recipient not null,

  created_at timestamptz not null default now(),

  constraint moderation_notices_subject_is_content
    check (subject_type in ('report', 'debate', 'comment', 'entry')),

  -- Same cap as moderation_actions.reason, because it is the same sentence stored twice:
  -- once for the log and once for the person. NOT NULL here and required by
  -- public.moderate() before it acts — a notice with nothing in it is worse than none,
  -- because it teaches people that the explanation is a formality.
  constraint moderation_notices_explanation_length
    check (length(btrim(explanation)) between 1 and 1000),

  constraint moderation_notices_label_length
    check (label is null or length(label) <= 200),

  -- One notice per person per decision. Somebody who flagged their own content — possible,
  -- and not worth forbidding — is told once.
  constraint moderation_notices_one_per_recipient
    unique (action_id, recipient_id)
);

comment on table public.moderation_notices is
  'A moderation decision as its subject reads it: outcome, explanation, and what it was '
  'about. One row per recipient. Written only by public.moderate(); readable by the '
  'recipient and by moderators. Never names the moderator or the flagger.';
comment on column public.moderation_notices.explanation is
  'The moderator''s sentence, shown to the author of the content and to whoever flagged it. '
  'The same text is kept in public.moderation_actions.reason.';
comment on column public.moderation_notices.recipient_role is
  'Why this person is being told. Two rows, not one, so the policy on this table is '
  'recipient_id = auth.uid() and nothing more.';

-- One person's decisions, newest first. That is the only way the page reads it.
create index moderation_notices_recipient_idx
  on public.moderation_notices (recipient_id, created_at desc);

-- "What has been decided about this row" — for the moderation screen, which shows the
-- history beside hidden content so a second moderator can see what the first one said.
create index moderation_notices_subject_idx
  on public.moderation_notices (subject_type, subject_id, created_at desc);

alter table public.moderation_notices enable row level security;

create policy moderation_notices_select_own
  on public.moderation_notices
  for select
  to authenticated
  using (recipient_id = (select auth.uid()));

create policy moderation_notices_select_moderator
  on public.moderation_notices
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

-- No INSERT, UPDATE or DELETE policy, and no grant for any of them. Rows arrive from
-- public.moderate() running as the owner, which policies do not apply to — the same
-- arrangement as public.moderation_actions and for the same reason. A notification a member
-- could forge is a notification nobody can trust.
grant select on public.moderation_notices to authenticated;

-- ── 5. Every decision needs an explanation ──────────────────────────────────────────
-- The old rule was that hiding, sending back and banning needed a reason and the rest did
-- not. The new rule is simpler and stricter: **everything except carrying out an erasure
-- request needs one**, because every remaining action is now a decision somebody will read.
-- An erasure is the exception because it is not a judgement — it is a standing request
-- being executed, and "the account holder asked" is not a sentence worth typing a hundred
-- times.
--
-- NOT VALID, deliberately. Rows written before today were legal under the old rule and are
-- history: an audit log whose past can be made to fail validation is one somebody will be
-- tempted to edit. New rows are checked in full — NOT VALID constrains inserts and updates
-- from the moment it exists and only skips the scan of what is already there.

alter table public.moderation_actions
  drop constraint moderation_actions_reason_required;

alter table public.moderation_actions
  add constraint moderation_actions_reason_required
    check (
      action = 'erase_account'
      or (reason is not null and length(btrim(reason)) >= 1)
    )
    not valid;

comment on constraint moderation_actions_reason_required on public.moderation_actions is
  'Every decision carries its explanation. NOT VALID so that rows from the pre-moderation '
  'era, written under a narrower rule, are left exactly as they were.';

-- ── 6. Automatic promotion goes with the queue it belonged to ───────────────────────
-- A debate used to promote itself once five people had rated it, which existed to get
-- claims out of a queue without a moderator. Nothing is in that queue now — a debate is
-- part of the record when it is posted — so the trigger has nothing left to promote and
-- would only fire against rows a moderator had hidden and unhidden.

drop trigger ratings_promote_debate on public.ratings;
drop function private.promote_debate();

delete from private.settings where key = 'debate_activation_ratings';

-- ── 7. public.moderate(), rewritten ─────────────────────────────────────────────────
-- Same door, different building behind it. What is unchanged: SECURITY DEFINER so it can
-- write rows the caller cannot, authorising on auth.uid() rather than current_user — which
-- is what makes DEFINER safe here and is the opposite of the trap in CLAUDE.md, since
-- auth.uid() is a JWT claim and reads the same inside a DEFINER function as in any policy.
-- It still refuses to act on the caller's own content, still refuses to ban somebody with
-- standing, and still writes its audit row in the same transaction as the effect.
--
-- What is new:
--
--   * **publish, request_changes and promote refuse.** They are the gate, and the gate is
--     gone. They raise a sentence saying so rather than silently doing nothing, because a
--     moderator who has not read this migration will press one.
--   * **Every action carries an explanation**, and that explanation becomes a notice for
--     each person owed one.
--   * **Hiding something closes the flags that named it.** Otherwise a moderator hides a
--     comment and three flags about that comment stay open, and whoever raised them is
--     never told the answer. Each closure is its own audit row — the log still says the
--     flag was resolved, by whom and when — and its own notice to the flagger.
--   * **resolve_flag is for a flag on something already gone.** Upholding a flag against
--     visible content is a `hide`, which closes the flag by itself. Left as a separate
--     action it would be a second, unlogged way to hide nothing while telling the flagger
--     something was done.
--
-- Reading order below: authorise, then check the explanation, then refuse the retired
-- actions, then one branch per target type.

create or replace function public.moderate(
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
  v_deleted     boolean := false;
  v_kind        public.content_kind;
  v_label       text;
  v_target_role text;
  v_user        uuid;
  v_audit       uuid;
  v_outcome     public.moderation_outcome;
  v_flag        record;
  v_flag_audit  uuid;
  v_subject     public.moderation_target;
  v_subject_id  uuid;
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

  -- ── The retired actions ───────────────────────────────────────────────────────────
  -- Refusing by name rather than falling through to "that action does not apply", so that
  -- the answer says what changed instead of reading like a bug.

  if p_action in ('publish', 'request_changes', 'promote') then
    raise exception
      'Posts are published when they are written; there is nothing to approve, send back or promote. What is left to decide is a flag: hide what it named, or leave it up. Either way, say why.'
      using errcode = '0A000';
  end if;

  -- ── The explanation ───────────────────────────────────────────────────────────────
  -- Everything but carrying out an erasure request. The same rule is a CHECK on
  -- public.moderation_actions; this copy exists so the refusal arrives as a sentence rather
  -- than as a constraint name.

  if p_action <> 'erase_account' and v_reason is null then
    raise exception
      'Every decision here needs an explanation. It is shown to whoever wrote the post and to whoever flagged it, so write it to them: one sentence saying what the problem is, or that there is not one.'
      using errcode = '23514';
  end if;

  -- ── Content: report, debate, comment, entry ───────────────────────────────────────
  -- One branch for all four, because there is now exactly one thing a moderator does to a
  -- piece of content — take it off the site, or put it back — and four copies of that would
  -- be four places for the notice to be forgotten.

  if p_target_type in ('report', 'debate', 'comment', 'entry') then

    if p_target_type = 'report' then
      select x.author_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.reports x
       where x.id = p_target_id;

    elsif p_target_type = 'debate' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.debates x
       where x.id = p_target_id;

    elsif p_target_type = 'comment' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.comments x
       where x.id = p_target_id;

    else
      select x.submitter_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.network_entries x
       where x.id = p_target_id;
    end if;

    if not found then
      raise exception 'That is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    -- Soft-deleted by its author, which is a stronger removal than a hide and not one a
    -- moderator should be able to paper over. The flag against it is still answerable —
    -- resolve_flag accepts a subject that has gone — so there is somewhere to go from here.
    if v_deleted then
      raise exception
        'Its author deleted that already. There is nothing left to hide; close the flag against it instead.'
        using errcode = '23514';
    end if;

    -- A moderator's own contributions go through the same reading as everybody else's.
    -- Nothing about post-moderation makes self-judgement safer than it was.
    if v_author is not distinct from v_actor then
      raise exception
        'This is your own post. Another moderator has to decide it — that has not changed, and it is the one shortcut that would make the record worthless.'
        using errcode = '42501';
    end if;

    if p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That is already hidden.'
          using errcode = '23514';
      end if;

      if p_target_type = 'report' then
        update public.reports set status = 'hidden' where id = p_target_id;
      elsif p_target_type = 'debate' then
        -- activated_at goes with it. debates_activated_iff_active ties the date to the
        -- status, so a hidden debate cannot keep one.
        update public.debates set status = 'hidden', activated_at = null where id = p_target_id;
      elsif p_target_type = 'comment' then
        update public.comments set status = 'hidden' where id = p_target_id;
      else
        update public.network_entries set status = 'hidden' where id = p_target_id;
      end if;

      v_outcome := 'hidden';

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That is not hidden.'
          using errcode = '23514';
      end if;

      -- Unhiding publishes. Nothing records what the status was before the hide, and
      -- inventing one would be worse than the plain reading: a moderator unhiding something
      -- has it in front of them and is deciding it may be read.
      if p_target_type = 'report' then
        update public.reports set status = 'published' where id = p_target_id;
      elsif p_target_type = 'debate' then
        update public.debates set status = 'active', activated_at = now() where id = p_target_id;
      elsif p_target_type = 'comment' then
        update public.comments set status = 'published' where id = p_target_id;
      else
        update public.network_entries set status = 'published' where id = p_target_id;
      end if;

      v_outcome := 'restored';

    else
      raise exception 'That action does not apply to a post.'
        using errcode = '23514';
    end if;

    insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
    values (v_actor, p_action, p_target_type, p_target_id, v_reason)
    returning id into v_audit;

    -- The author is told what was decided and why. Null when the account has been erased,
    -- and then there is nobody to tell.
    v_label := private.activity_label(p_target_type, p_target_id);

    if v_author is not null then
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, p_target_type, p_target_id, v_label, v_outcome, v_reason, v_author, 'author'
      );
    end if;

    -- ── The flags that named it ─────────────────────────────────────────────────────
    -- Hiding answers every open flag against this row at once. Each closure is a real audit
    -- row, so the log still reads "this flag was resolved, by this person, then" — and each
    -- flagger gets the same sentence the author got.
    --
    -- Only for the three flaggable kinds: public.flags.subject_type is public.content_kind,
    -- which has no `entry`, because a network entry cannot be flagged.

    if p_action = 'hide' and p_target_type in ('report', 'debate', 'comment') then
      v_kind := case p_target_type
                  when 'report'  then 'report'::public.content_kind
                  when 'debate'  then 'debate'::public.content_kind
                  when 'comment' then 'comment'::public.content_kind
                end;

      for v_flag in
        select f.id, f.flagger_id
          from public.flags f
         where f.subject_type = v_kind
           and f.subject_id = p_target_id
           and f.status = 'open'
         order by f.created_at
      loop
        update public.flags
           set status = 'actioned', resolved_at = now(), resolved_by = v_actor
         where id = v_flag.id;

        insert into public.moderation_actions
          (actor_id, action, target_type, target_id, reason)
        values (v_actor, 'resolve_flag', 'flag', v_flag.id, v_reason)
        returning id into v_flag_audit;

        -- Not to the author twice: they already have the notice above, and a moderator's
        -- own flag needs no answer from themselves.
        if v_flag.flagger_id is not null
           and v_flag.flagger_id is distinct from v_author
           and v_flag.flagger_id is distinct from v_actor then
          insert into public.moderation_notices (
            action_id, subject_type, subject_id, label, outcome, explanation,
            recipient_id, recipient_role
          )
          values (
            v_flag_audit, p_target_type, p_target_id, v_label, 'hidden', v_reason,
            v_flag.flagger_id, 'flagger'
          );
        end if;
      end loop;
    end if;

    return v_audit;

  -- ── Flags ─────────────────────────────────────────────────────────────────────────
  -- Two answers, and they are not interchangeable: the content came down, or it stayed up.
  -- Dismissing is the one that needs the most care to write, because it is the answer a
  -- flagger disagrees with and the one an author never knew was coming.

  elsif p_target_type = 'flag' then
    select f.status::text, f.flagger_id, private.as_target(f.subject_type), f.subject_id
      into v_status, v_user, v_subject, v_subject_id
      from public.flags f
     where f.id = p_target_id;

    if not found then
      raise exception 'That flag is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_status <> 'open' then
      raise exception 'That flag has already been dealt with.'
        using errcode = '23514';
    end if;

    if p_action not in ('resolve_flag', 'dismiss_flag') then
      raise exception 'That action does not apply to a flag.'
        using errcode = '23514';
    end if;

    -- A moderator who raises a flag is asking somebody else to look. Deciding it yourself
    -- is the same shortcut as publishing your own submission used to be.
    if v_user is not distinct from v_actor then
      raise exception
        'This is your own flag. Another moderator has to answer it.'
        using errcode = '42501';
    end if;

    -- Who wrote the thing that was flagged, and is it still visible. v_status is reused for
    -- the subject's status from here on; SELECT INTO sets it to null when the row has gone
    -- outright, which is why the test below coalesces rather than comparing.
    if v_subject = 'report' then
      select x.author_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.reports x where x.id = v_subject_id;
    elsif v_subject = 'debate' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.debates x where x.id = v_subject_id;
    else
      select x.author_id, x.status::text
        into v_author, v_status
        from public.comments x where x.id = v_subject_id;
    end if;

    if p_action = 'resolve_flag' and coalesce(v_status, 'gone') not in ('hidden', 'gone')
       and not v_deleted then
      raise exception
        'What this flag named is still on the site. Hide it — that closes this flag and every other one against it — or dismiss the flag and say why it stays.'
        using errcode = '23514';
    end if;

    update public.flags
       set status = case when p_action = 'resolve_flag'
                         then 'actioned'::public.flag_status
                         else 'dismissed'::public.flag_status
                    end,
           resolved_at = now(),
           resolved_by = v_actor
     where id = p_target_id;

    insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
    values (v_actor, p_action, 'flag', p_target_id, v_reason)
    returning id into v_audit;

    v_outcome := case when p_action = 'resolve_flag' then 'hidden' else 'kept' end;
    v_label   := private.activity_label(v_subject, v_subject_id);

    insert into public.moderation_notices (
      action_id, subject_type, subject_id, label, outcome, explanation,
      recipient_id, recipient_role
    )
    values (
      v_audit, v_subject, v_subject_id, v_label, v_outcome, v_reason, v_user, 'flagger'
    );

    -- **The author is told about a dismissal.** They were never told the flag was filed —
    -- that invites them to work out who — but a decision that their post stays up is a
    -- decision about their post, and the corpus is better if authors know their work has
    -- been looked at and left alone. On resolve_flag they are not told again: the hide that
    -- preceded it carried the same sentence.
    if p_action = 'dismiss_flag'
       and v_author is not null
       and v_author is distinct from v_user
       and v_author is distinct from v_actor then
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, v_subject, v_subject_id, v_label, 'kept', v_reason, v_author, 'author'
      );
    end if;

    return v_audit;

  -- ── Accounts ──────────────────────────────────────────────────────────────────────
  -- Unchanged, except that unbanning now needs a sentence like everything else.

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
      -- already written into the foreign keys. Since today that includes
      -- public.moderation_notices, which cascades: a message addressed to somebody who no
      -- longer exists is not a record, it is an undeliverable letter.
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

  -- Only the account branch reaches here; content and flags return from inside their own
  -- branch, because each writes more than one row and the shape of the log entry differs.
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
  'The only audited route for a moderation decision, and since the move to post-moderation '
  'the only one that matters is answering a flag. Every action carries an explanation, which '
  'reaches the author and the flagger as public.moderation_notices. SECURITY DEFINER so it '
  'can write rows the caller cannot; authorises on auth.uid(), which is what makes that safe.';

-- ── 8. The feed follows ─────────────────────────────────────────────────────────────
-- public.activity is the other half of telling somebody: the notice is the sentence, the
-- feed row is what makes them look. Three changes, all consequences of the above.

-- A new kind. An author whose post was flagged and kept has been told nothing by any
-- existing value: content_hidden is wrong, and flag_dismissed belongs to the flagger.
alter type public.activity_kind add value if not exists 'content_kept';

comment on type public.activity_kind is
  'Every event that can appear in an activity feed. Adding a value requires a branch in '
  'the is_inbound CASE inside private.log_activity(), which has no ELSE. The values naming '
  'publication and change requests are pre-moderation history: nothing writes them now, and '
  'rows carrying them are still in feeds.';

-- Editing is now something an author does to *hidden* work, not to pending work. Without
-- this the trigger watches for a state nothing reaches and an author's revision goes
-- unrecorded in their own feed.
drop trigger reports_activity_update on public.reports;

create trigger reports_activity_update
  after update on public.reports
  for each row
  when (
    new.status = 'hidden'
    and new.deleted_at is null
    and (old.title, old.aim, old.method, old.outcome_notes, old.verification)
        is distinct from
        (new.title, new.aim, new.method, new.outcome_notes, new.verification)
  )
  execute function private.activity_on_report();

comment on function private.activity_on_report() is
  'Feed rows for posting a report and for revising a hidden one. Both are the author''s own '
  'acts, so neither counts as unread.';

-- The classification of the new kind. The CASE inside private.log_activity() has no ELSE, so
-- a value added to the enum without a branch here raises CASE_NOT_FOUND naming it rather
-- than quietly never counting as unread — which is why the whole function is reissued for
-- one line. Being told your post was looked at and kept is something that happened *to* you,
-- so it counts as unread like every other decision.

create or replace function private.log_activity(
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
  if p_subject is null or p_target_id is null then
    return;
  end if;

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

    -- The first four are pre-moderation history. Nothing writes them any more; feeds built
    -- before today still carry them, so a branch removed here would break reading rather
    -- than writing.
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

  -- Never notify somebody about their own act.
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
    -- capped well below 200 characters but a debate statement is not, and a notification is
    -- not the place a length rule should first be discovered.
    nullif(left(btrim(coalesce(p_label, '')), 200), '')
  );
end;
$$;

-- The decisions a feed row can now report are hide, unhide, and the two answers to a flag.
-- Three things follow from post-moderation, and the third is the one worth reading twice:
--
--   * publish, request_changes and promote no longer arrive, so their branches go. The
--     activity *kinds* stay, because rows carrying them are in people's feeds.
--   * a `resolve_flag` row is now usually written by a hide, in the same transaction, one
--     per open flag. That needs no special case here: one audit row still produces one feed
--     row, and the flagger is owed exactly that.
--   * **a dismissal tells two people.** The flagger is told their flag was answered; the
--     author is told their post was looked at and left where it was. This is the one place a
--     content author learns a flag existed at all, and it is deliberate — a decision about
--     your post is yours to know. It still never says who flagged it, and the explanation
--     itself arrives as public.moderation_notices rather than through this table.

create or replace function private.activity_on_moderation()
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
  v_author     uuid;
  v_flagger    uuid;
  v_kept       public.moderation_target;
  v_kept_id    uuid;
  v_kept_comment uuid;
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
      when 'hide'   then 'content_hidden'
      when 'unhide' then 'content_unhidden'
    end;

  elsif new.target_type = 'debate' then
    select x.author_id, x.statement into v_subject, v_label
      from public.debates x where x.id = new.target_id;

    v_kind := case new.action
      when 'hide'   then 'content_hidden'
      when 'unhide' then 'content_unhidden'
    end;

  elsif new.target_type = 'entry' then
    select x.submitter_id, x.title into v_subject, v_label
      from public.network_entries x where x.id = new.target_id;

    v_kind := case new.action
      when 'hide'   then 'content_hidden'
      when 'unhide' then 'content_unhidden'
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
    -- asked for the decision rather than the person it was about. The target stays the flag
    -- and stays unlinked: what it named may now be hidden, and a link the flagger cannot
    -- open is worse than no link.
    select f.flagger_id,
           private.as_target(f.subject_type),
           f.subject_id,
           private.activity_label(private.as_target(f.subject_type), f.subject_id)
      into v_flagger, v_kept, v_kept_id, v_label
      from public.flags f where f.id = new.target_id;

    v_subject := v_flagger;

    v_kind := case new.action
      when 'resolve_flag' then 'flag_resolved'
      when 'dismiss_flag' then 'flag_dismissed'
    end;

    -- The author's half of a dismissal. Written from this row rather than from a second
    -- audit row, because there was one decision and the log should say so once.
    if new.action = 'dismiss_flag' then
      if v_kept = 'report' then
        select x.author_id into v_author from public.reports x where x.id = v_kept_id;
      elsif v_kept = 'debate' then
        select x.author_id into v_author from public.debates x where x.id = v_kept_id;
      else
        -- A comment again resolves onto its thread, so the author's row links to the page
        -- their comment is on and carries the fragment that finds it.
        v_kept_comment := v_kept_id;

        select c.author_id, c.parent_type, c.parent_id
          into v_author, v_parent, v_kept_id
          from public.comments c where c.id = v_kept_comment;

        v_kept := private.as_target(v_parent);
      end if;

      if v_author is not null and v_author is distinct from v_flagger then
        perform private.log_activity(
          v_author, 'content_kept', null, v_kept, v_kept_id, v_kept_comment,
          private.activity_label(v_kept, v_kept_id)
        );
      end if;
    end if;
  end if;

  -- A kind with no branch is not an error: the CASE expressions above return null, so a
  -- value added to public.moderation_action later will land here rather than raise. A
  -- missing notification is the right failure for a log that has already recorded the
  -- decision — the audit row is the record, and this table is a courtesy.
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
  'Turns each row of public.moderation_actions into feed rows for the people it was about: '
  'the author of the content, and the flagger. Never names the moderator and never copies '
  'the reason — the reason reaches them as public.moderation_notices instead.';

-- ── 9. Resubmitting, which now means revising ───────────────────────────────────────
-- public.resubmit_report() is unchanged except for the sentence it raises when the update
-- matches nothing. It is SECURITY INVOKER, so it never knew which state was editable — the
-- caller's policies decided, and today reports_update_own_editable is the one that answers.
-- What it must not do is keep telling an author their submission "is no longer pending",
-- which is now a state that never existed for them.

create or replace function public.resubmit_report(
  p_report_id                      uuid,
  p_title                          text,
  p_area                           public.report_area,
  p_task_type                      public.report_task_type,
  -- [{"name": "GPT-5", "version": "2026-05", "used_on": "2026-08-01"}, ...]
  p_tools                          jsonb,
  p_aim                            text,
  p_method                         text,
  p_outcome                        public.report_outcome,
  p_outcome_notes                  text,
  p_verification                   text,
  p_third_party_material_confirmed boolean,
  p_transcript_excerpt             text     default null,
  p_transcript_url                 text     default null,
  p_caveats                        text     default null,
  p_time_spent_minutes             integer  default null,
  p_was_published                  boolean  default null,
  p_was_disclosed                  boolean  default null,
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
  -- Validate tool count before touching anything, so the error message names the form field
  -- rather than a constraint. The deferred trigger is still the true enforcer.
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

  -- The update matches zero rows if the report does not exist, is not the caller's, or is
  -- no longer editable — reports_update_own_editable refuses it. Check the count so the
  -- caller gets a clear error rather than silent success followed by a puzzling state.
  update public.reports set
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
  where id = p_report_id;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception
      'This report was not found, or it can no longer be edited. A report is editable while it is hidden, and until somebody else has confirmed or commented on it — after that the text is fixed, because their answer attests to a version.'
      using errcode = 'P0002';
  end if;

  -- Replace tools atomically. The deferred constraint sees the final state — the new rows
  -- inserted below — rather than the empty intermediate.
  delete from public.report_tools where report_id = p_report_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.report_tools (report_id, tool_name, tool_version, used_on)
    values (
      p_report_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date
    );
  end loop;

  -- Replace tags. Unknown or retired codes are silently dropped, as in submit_report.
  delete from public.report_tags where report_id = p_report_id;

  insert into public.report_tags (report_id, tag_id)
  select p_report_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;
end;
$$;

comment on function public.resubmit_report is
  'Replaces an editable report''s content, tools, and tags in one transaction. It does not '
  'unhide anything: status is reverted by the guard trigger, so revising is the author''s '
  'half of the exchange and unhiding stays a logged moderator decision.';
