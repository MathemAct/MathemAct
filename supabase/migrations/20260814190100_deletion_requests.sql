-- public.deletion_requests — a person asking for their account to be erased.
--
-- Erasure is a documented, working flow rather than an email into a void; CLAUDE.md calls
-- it a genuine advantage of a database over a git-backed store, and it is one of the four
-- things the privacy notice promises. This table is the record that the request was made.
-- Acting on it is manual and belongs to a later prompt; nothing here deletes anything.
--
-- Why the request is a row rather than a mailto
-- ---------------------------------------------
-- A mailto cannot prove the request came from the account it names. This can: the row is
-- written by an authenticated session, so the user_id is established by the session rather
-- than typed in. That also means the request never carries an email address, which matters
-- because nothing in the exposed schema is allowed to.
--
-- Deliberately absent: any UPDATE grant or policy. A request is created, withdrawn, or
-- resolved by an operator with direct database access. The status column exists for that
-- operator and is unreachable from the browser in either direction.

create table public.deletion_requests (
  id uuid primary key default gen_random_uuid(),

  -- Cascade rather than restrict. When the account is finally deleted the request goes
  -- with it, which is the correct end state: keeping a row that says "this user id asked
  -- to be erased" after erasing them would preserve exactly the fact they asked us to
  -- forget. The operator's own record of having acted lives outside this database.
  user_id uuid not null references auth.users (id) on delete cascade,

  -- Optional. The privacy notice offers "if you want specific posts deleted as well, say
  -- so"; this is where that is said.
  note text,

  status       text not null default 'pending',
  requested_at timestamptz not null default now(),
  resolved_at  timestamptz,

  constraint deletion_requests_status_valid
    check (status in ('pending', 'completed', 'cancelled')),

  constraint deletion_requests_note_length
    check (note is null or length(note) <= 1000),

  -- A pending request has no resolution date and a resolved one has exactly one, so the
  -- state cannot drift out of step with the timestamp that is supposed to explain it.
  constraint deletion_requests_resolved_iff_not_pending
    check ((status = 'pending') = (resolved_at is null))
);

comment on table public.deletion_requests is
  'Standing requests for account erasure. Written by the account holder, acted on by hand. '
  'Contains no email address; the account it refers to is identified by user_id.';
comment on column public.deletion_requests.note is
  'Anything the person wants the operator to know, e.g. specific posts to delete outright '
  'rather than detach.';
comment on column public.deletion_requests.status is
  'Operator-owned. There is no UPDATE grant and no UPDATE policy, so this cannot be '
  'changed from a browser.';

-- One open request per account. Partial, so a withdrawn-and-remade request is fine and a
-- completed one does not block anything. Without it, a double-submitted form would leave
-- an operator wondering whether the second row meant something different.
create unique index deletion_requests_one_pending_per_user
  on public.deletion_requests (user_id)
  where status = 'pending';

create index deletion_requests_pending_idx
  on public.deletion_requests (requested_at)
  where status = 'pending';

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.deletion_requests enable row level security;

-- Your own request, and nobody else's. Note the contrast with profiles, which are public:
-- the fact that a particular person is leaving is not.
create policy deletion_requests_select_own
  on public.deletion_requests
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Admins read all of them, because someone has to work the queue. Moderators do not:
-- erasure is an account action, not a content action, and the moderation UI has no reason
-- to know who has asked to leave.
create policy deletion_requests_select_admin
  on public.deletion_requests
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.role = 'admin'
         and not p.is_banned
    )
  );

-- You may only file a request for yourself. The WITH CHECK is what makes user_id a fact
-- about the session rather than a field on a form.
create policy deletion_requests_insert_own
  on public.deletion_requests
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

-- Withdrawing is a delete rather than a status change, so that changing your mind leaves
-- nothing behind at all. Only while pending: a completed request describes something that
-- already happened and is not the requester's to erase.
create policy deletion_requests_delete_own_pending
  on public.deletion_requests
  for delete
  to authenticated
  using (user_id = (select auth.uid()) and status = 'pending');

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- New tables are not auto-exposed in this project, so without these the table has no
-- endpoint at all. Grants decide whether the endpoint exists; policies decide which rows
-- it returns. Nothing is granted to anon: an anonymous caller has no account to erase.

grant select, delete on public.deletion_requests to authenticated;

-- INSERT is granted per column, exactly as on profiles. status, resolved_at, requested_at
-- and id are absent, so an attempt to file a pre-resolved request is refused by Postgres
-- before any policy is consulted. Columns left out of an INSERT statement still take their
-- defaults; a grant is only needed for columns the caller actually names.
grant insert (user_id, note) on public.deletion_requests to authenticated;
