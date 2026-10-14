-- public.debate_tags — which arXiv subject classes a claim is about.
--
-- The vocabulary is the one that already exists. `public.tags` holds the 32 arXiv mathematics
-- categories, seeded by 20260815100400 and writable by no browser role, and reports have used
-- it since. Inventing a second vocabulary for debates would mean two lists that drift and a
-- reader who has to learn which page uses which — and the question a tag answers is the same on
-- both surfaces: *which part of mathematics is this about.*
--
-- So this is `public.report_tags` with one column renamed, and the differences from it are all
-- consequences of debates having no pending state.
--
-- Why the write policies are not report_tags' write policies
-- ---------------------------------------------------------
-- `report_tags` gates its INSERT and DELETE on `p.status = 'pending'`, from the period when a
-- report waited for approval and its author could still edit it. A debate has never had that
-- state and has not had an approval queue since 2026-08-18: it is part of the record the moment
-- it is written.
--
-- The rule here is instead the one that governs the claim itself. **A debate's wording freezes
-- once somebody other than its author has rated it** — people answered the sentence in front of
-- them — and its tags freeze with it, because a tag is part of what the claim was taken to be
-- about.
--
-- "Somebody other than its author" is doing real work in that sentence, and getting it wrong here
-- would have made these policies unusable. 20260822110300 requires the proposer to place
-- themselves on the scale as part of creating the debate, so **a rating always exists from the
-- moment a debate does.** A policy testing for *any* rating would therefore refuse every tag,
-- including the ones `public.submit_debate()` inserts three lines after the proposer's own — the
-- feature would have been dead on arrival, in a way no single migration reads as wrong.
--
-- So the condition is a rating by somebody else, which is the same rule 20260822110250 puts in
-- the wording freeze and the same one `private.mark_report_answered()` states for reports: your
-- own answer is not an answer. The window it leaves open is the real one — the proposer may fix a
-- mistagged claim until the first other person answers — and it closes by itself.

create table public.debate_tags (
  debate_id uuid not null references public.debates (id) on delete cascade,
  -- RESTRICT, matching report_tags: retiring a tag is `is_active = false`, never a delete that
  -- would silently untag existing work.
  tag_id    uuid not null references public.tags (id) on delete restrict,

  created_at timestamptz not null default now(),

  primary key (debate_id, tag_id)
);

comment on table public.debate_tags is
  'Which arXiv subject classes a claim is about, from the same vocabulary reports use. Frozen '
  'once somebody other than the author has rated the debate, because a tag is part of what the '
  'claim was taken to be about. The author''s own rating does not freeze it — see 20260822110250.';

create index debate_tags_tag_idx on public.debate_tags (tag_id);

alter table public.debate_tags enable row level security;

-- ── Reading ─────────────────────────────────────────────────────────────────────────
-- Visibility defers entirely to the parent debate. The subquery runs under the caller's own row
-- level security, so a hidden debate's tags disappear with it and the rule lives in one place
-- rather than being restated here and drifting.

create policy debate_tags_select_with_parent
  on public.debate_tags
  for select
  to anon, authenticated
  using (
    exists (select 1 from public.debates q where q.id = debate_id)
  );

-- ── Writing ─────────────────────────────────────────────────────────────────────────
-- Your own debate, and only while nobody else has answered it. Both halves matter: the first is
-- ownership, the second is the same freeze that fixes the wording.

create policy debate_tags_insert_own_unanswered
  on public.debate_tags
  for insert
  to authenticated
  with check (
    exists (
      select 1
        from public.debates q
       where q.id = debate_id
         and q.author_id = (select auth.uid())
    )
    -- Somebody *else*. See the header: the proposer's own rating always exists, so testing for
    -- any rating at all would refuse every tag this table was created to hold.
    and not exists (
      select 1
        from public.ratings r
       where r.debate_id = debate_id
         and r.user_id is distinct from (select auth.uid())
    )
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
  );

-- Removing one, on the same terms. A real delete rather than a soft one: a tag is a pointer with
-- no prose and nothing threaded under it, so there is nothing for a tombstone to preserve — the
-- same reasoning that makes public.citations the site's other hard delete.
create policy debate_tags_delete_own_unanswered
  on public.debate_tags
  for delete
  to authenticated
  using (
    exists (
      select 1
        from public.debates q
       where q.id = debate_id
         and q.author_id = (select auth.uid())
    )
    and not exists (
      select 1
        from public.ratings r
       where r.debate_id = debate_id
         and r.user_id is distinct from (select auth.uid())
    )
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and not p.is_banned
    )
  );

-- No UPDATE policy and no UPDATE grant. A row here is two foreign keys; changing either one is
-- a different row, so an update has nothing to express that a delete and an insert do not.

-- ── Grants ──────────────────────────────────────────────────────────────────────────
-- Nothing is auto-exposed in this project, and a missing grant is indistinguishable from a
-- missing policy when the client sees it.
--
-- `created_at` is absent from the INSERT list on purpose, as it is everywhere: the default is
-- the only way a row gets one, which is what `private.log_activity()`'s dedup guard relies on
-- across the whole schema.

grant select on public.debate_tags to anon, authenticated;
grant insert (debate_id, tag_id) on public.debate_tags to authenticated;
grant delete on public.debate_tags to authenticated;
