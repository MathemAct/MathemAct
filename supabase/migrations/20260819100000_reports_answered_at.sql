-- "Has anybody answered this report?" becomes a column, because as a subquery it recurses.
--
-- 20260818180000 made a report editable by its author while it is hidden, and until somebody
-- else has confirmed or commented on it. It wrote that second half as two `not exists`
-- subqueries inside `reports_update_own_editable` — and a policy on public.reports that
-- reads public.comments is a policy that calls a policy that reads public.reports:
--
--   ERROR: infinite recursion detected in policy for relation "reports"
--
-- Both subqueries do it. `comments_select_visible` checks that the parent report is
-- published; `report_confirmations_select_with_parent` checks that the parent report is
-- visible at all. Each is correct on its own, and each closes the loop.
--
-- The rule is right and stays. What changes is where the answer comes from: a column on the
-- report, set by a trigger the first time somebody else responds to it. Three things follow
-- and all of them are improvements rather than concessions:
--
--   * The policy becomes `status = 'hidden' or answered_at is null` — no subquery, nothing
--     to recurse, and one indexable comparison instead of two correlated scans on every row
--     of every update.
--   * The same expression works in the guard trigger and in the tools and tags policies, so
--     the rule is one phrase repeated rather than a ten-line predicate repeated.
--   * The browser stops asking. src/lib/reports.ts had to run two extra queries to decide
--     whether to offer an author the edit link; now it reads a column it was already
--     selecting the row for.
--
-- What "answered" means, exactly: somebody **other than the author** has confirmed the
-- report still works, or commented on it. Confirming or commenting on your own report is
-- allowed and does not freeze it — nothing about your own answer attests to a version for
-- anybody else.

alter table public.reports add column answered_at timestamptz;

comment on column public.reports.answered_at is
  'When somebody other than the author first confirmed or commented on this report. Null '
  'means nobody has, and the author may still correct the text. Written only by '
  'private.mark_report_answered(); there is no column grant for it in either direction.';

-- Existing rows. The corpus is empty today, so this is a no-op — and it is here because a
-- migration that only works on an empty database is a migration that has not been written.
update public.reports r
   set answered_at = answers.first_at
  from (
    select report_id, min(created_at) as first_at
      from (
        select c.report_id, c.created_at
          from public.report_confirmations c
          join public.reports p on p.id = c.report_id
         where c.user_id is distinct from p.author_id
        union all
        select m.parent_id, m.created_at
          from public.comments m
          join public.reports p on p.id = m.parent_id
         where m.parent_type = 'report'
           and m.author_id is distinct from p.author_id
      ) as responses (report_id, created_at)
     group by report_id
  ) as answers
 where r.id = answers.report_id;

-- ── The writer ──────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER, and this is the safe direction of the trap rather than an instance of
-- it: nothing here asks who is running the statement. It is DEFINER for the same reason
-- private.log_activity() is — the person writing a comment has no UPDATE privilege on
-- somebody else's report, and must not need one to leave a mark on it.
--
-- `coalesce` rather than a plain assignment: the first answer is the one that freezes the
-- text, and a later one must not move the date forward. Written as a WHERE clause so a
-- report that already has one is not updated at all, which keeps the guard trigger and the
-- activity trigger on public.reports from firing on every comment posted anywhere.

create function private.mark_report_answered()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report uuid;
  v_actor  uuid;
begin
  if tg_table_name = 'report_confirmations' then
    v_report := new.report_id;
    v_actor  := new.user_id;
  else
    -- The trigger's WHEN clause already restricts this to comments on reports.
    v_report := new.parent_id;
    v_actor  := new.author_id;
  end if;

  update public.reports r
     set answered_at = new.created_at
   where r.id = v_report
     and r.answered_at is null
     -- Your own answer is not an answer. An author correcting their own report in the thread
     -- should not thereby lose the ability to correct the report.
     and r.author_id is distinct from v_actor;

  return null;
end;
$$;

comment on function private.mark_report_answered() is
  'Stamps public.reports.answered_at the first time somebody other than the author confirms '
  'or comments on it. DEFINER because a commenter has no privilege on the report, and must '
  'not need one.';

revoke all on function private.mark_report_answered() from public;

create trigger report_confirmations_mark_answered
  after insert on public.report_confirmations
  for each row
  execute function private.mark_report_answered();

create trigger comments_mark_report_answered
  after insert on public.comments
  for each row
  when (new.parent_type = 'report')
  execute function private.mark_report_answered();

-- ── The policies, without the recursion ─────────────────────────────────────────────

drop policy reports_update_own_editable on public.reports;

create policy reports_update_own_editable
  on public.reports
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and deleted_at is null
    and (status = 'hidden' or answered_at is null)
  )
  with check (
    author_id = (select auth.uid())
    and (status = 'hidden' or answered_at is null)
  );

drop policy report_tools_insert_own_editable on public.report_tools;
drop policy report_tools_update_own_editable on public.report_tools;
drop policy report_tools_delete_own_editable on public.report_tools;
drop policy report_tags_insert_own_editable  on public.report_tags;
drop policy report_tags_delete_own_editable  on public.report_tags;

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
         and (p.status = 'hidden' or p.answered_at is null)
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
         and (p.status = 'hidden' or p.answered_at is null)
    )
  )
  with check (
    exists (
      select 1
        from public.reports p
       where p.id = report_id
         and p.author_id = (select auth.uid())
         and p.deleted_at is null
         and (p.status = 'hidden' or p.answered_at is null)
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
         and (p.status = 'hidden' or p.answered_at is null)
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
         and (p.status = 'hidden' or p.answered_at is null)
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
         and (p.status = 'hidden' or p.answered_at is null)
    )
  );

-- ── The guard, saying the same thing ────────────────────────────────────────────────
-- Reissued in full rather than patched, because a guard read in two halves is a guard read
-- wrong. The only changes from 20260818180000 are the freeze condition and the line that
-- makes answered_at immutable to everyone who is not the trigger above.

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
  -- `authenticated` for a browser, the table's owner when public.moderate() performs the
  -- update, and the owner again when private.mark_report_answered() stamps the date. As
  -- DEFINER this would always be the owner and the guard would never fire — which is the
  -- trap recorded in CLAUDE.md and the reason this line reads the way it does.
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

  -- Nor is the date somebody else's answer put there. There is no column grant for it
  -- either; this is the second lock, for the day somebody widens the first.
  new.answered_at := old.answered_at;

  -- Restoring a deleted report is a moderation action, not an authoring one. Without this,
  -- "delete" would be a toggle and a soft-deleted row could be brought back after the
  -- discussion around it had moved on.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- **The text is fixed once somebody else has answered, and unfixed again while it is
  -- hidden.** An account that can be rewritten after people have confirmed it still works is
  -- not a record of anything — the confirmations would attest to a version nobody can read.
  -- Until anybody has answered there is nothing pointing at the old text, so a correction
  -- misleads nobody; and hidden content is off the site with its author holding a written
  -- reason, which is exactly when rewriting it is the point.
  --
  -- The same condition is in reports_update_own_editable, which is what actually refuses the
  -- statement. This is the second lock, and it is the one that decides *columns* — an author
  -- whose report is still editable may change the text and still may not touch `status`.
  if old.status <> 'hidden' and old.answered_at is not null then
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
  'hidden, and until answered_at is set. Deliberately SECURITY INVOKER: as DEFINER, '
  'current_user would always be the owner and the guard would never fire.';
