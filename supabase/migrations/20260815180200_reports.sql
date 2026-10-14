-- public.reports — somebody telling the moderators about a row.
--
-- Added here because prompt 10 puts a report control on every comment, and a control that
-- files nothing is worse than no control: it teaches people that reporting does nothing.
-- CLAUDE.md has always required this table; this is the minimum shape of it.
--
-- It lives in `public` rather than `private` because the moderation UI reads it from a
-- browser, which CLAUDE.md flags as making these policies the ones that deserve the closest
-- review. Two rules do most of the work:
--
--   A reporter can read their own reports and nobody else's. Without that, the table is a
--   list of who has complained about whom, readable by everyone it names.
--   Nothing here is ever shown next to the reported content. A report is a message to the
--   moderators, not a public downvote, and a visible report count would turn it into one.
--
-- No moderation_actions table yet. When one arrives it records what was done; this records
-- what was asked.

create type public.report_reason as enum (
  -- Not about AI use in mathematical work.
  'off_topic',
  -- Abuse, harassment, or a breach of the code of conduct.
  'abusive',
  -- Somebody else's unpublished work in a transcript or a quotation. First-class here
  -- rather than folded into "other" because it is the specific hazard this site creates:
  -- the submission form asks authors to paste real conversations.
  'third_party_material',
  -- A claim about what a tool did that the reporter believes is wrong.
  'inaccurate',
  'spam',
  'other'
);

create type public.report_status as enum ('open', 'actioned', 'dismissed');

create table public.reports (
  id uuid primary key default gen_random_uuid(),

  -- All three kinds, unlike comments and citations. A practice, a proposition and a comment
  -- are all reportable, and the moderator needs to know which without three tables.
  subject_type public.content_kind not null,
  subject_id   uuid not null,

  -- SET NULL rather than CASCADE: an erased account's reports stay open. The moderator
  -- still has to decide about the reported content, and the decision does not depend on
  -- who raised it.
  reporter_id uuid references public.profiles (id) on delete set null,

  reason public.report_reason not null,
  detail text,

  status public.report_status not null default 'open',

  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id) on delete set null,

  constraint reports_detail_length
    check (detail is null or length(btrim(detail)) between 1 and 1000),

  -- One report per person per thing. Reporting twice is not a stronger signal, and without
  -- this the queue can be filled by one person pressing a button repeatedly.
  constraint reports_one_per_reporter
    unique (subject_type, subject_id, reporter_id),

  constraint reports_resolution_all_or_nothing
    check ((status = 'open') = (resolved_at is null)),
  constraint reports_resolved_has_hand
    check (resolved_at is not null or resolved_by is null)
);

comment on table public.reports is
  'Reports of content, readable by their author and by moderators and nobody else. Never '
  'displayed next to the reported row: a visible report count is a downvote.';

-- Oldest first: the queue is worked from the front.
create index reports_open_idx
  on public.reports (created_at)
  where status = 'open';

create index reports_subject_idx on public.reports (subject_type, subject_id);

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.reports enable row level security;

-- Your own, so the interface can say "you have already reported this" rather than failing
-- on the unique constraint with a message about an index.
create policy reports_select_own
  on public.reports
  for select
  to authenticated
  using (reporter_id = (select auth.uid()));

create policy reports_select_moderator
  on public.reports
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

-- Nothing to `anon`. Anonymous reporting sounds generous and produces a queue nobody can
-- weigh: a volunteer moderator's first question about a report is who filed it and what
-- else they have filed.
create policy reports_insert_own
  on public.reports
  for insert
  to authenticated
  with check (
    reporter_id = (select auth.uid())
    and status = 'open'
    and resolved_at is null
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

-- Only moderators resolve. A reporter cannot withdraw, edit or reopen: the queue is a
-- record of what was raised, and a report that can be retracted after a moderator has read
-- it makes the log incomplete in exactly the cases that matter.
create policy reports_update_moderator
  on public.reports
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

-- No DELETE policy and no DELETE grant.

-- ── Grants ──────────────────────────────────────────────────────────────────────────

-- Nothing to anon, not even SELECT. The policies would refuse every row anyway; the
-- absent grant means the endpoint does not exist for an anonymous caller at all.
grant select on public.reports to authenticated;

grant insert (subject_type, subject_id, reporter_id, reason, detail)
  on public.reports to authenticated;

grant update (status, resolved_at, resolved_by) on public.reports to authenticated;
