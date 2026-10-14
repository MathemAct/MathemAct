-- public.citations — one piece of the corpus pointing at another.
--
-- This is the table that makes the two halves of the site one thing. Without it a practice
-- and a proposition are separate documents that happen to share a stylesheet; with it, the
-- proposition "every AI-generated proof step must be checked by a human" carries the three
-- accounts that motivated it, and each of those accounts shows the argument it started.
--
-- What an endpoint is
-- -------------------
-- Source and target are each a practice or a proposition. Comments are not endpoints: a
-- citation graph in which every remark is a node is a graph nobody can read, and the useful
-- question is "which practices bear on this proposition", not "which sentence did somebody
-- quote". But a quotation almost always comes *from* a comment or lands *in* one, so both
-- ends carry an optional comment id alongside. The graph stays coarse; the provenance stays
-- exact. `source_comment_id` is what lets a "referenced by" entry link straight to the
-- paragraph that did the referencing.
--
-- Why there are no foreign keys on the endpoints
-- ----------------------------------------------
-- Same reason as public.comments: the reference is polymorphic. And the same three
-- substitutes — a CHECK fixing the vocabulary, policies requiring both ends to be visible
-- to the caller, and immutability, which here is total. There is no UPDATE grant on this
-- table at all. A citation is a claim about what somebody quoted; edit it and it stops
-- being that.
--
-- The one hard delete on the site
-- -------------------------------
-- Everything else here is soft-deleted, because everything else has replies hanging off it
-- or attribution to preserve. A citation has neither: it is a link, its excerpt is a
-- verbatim copy of text that still exists at the target, and nothing is threaded under it.
-- So the citer may remove one outright and a moderator may remove one whose excerpt should
-- not be there. See docs/decisions.md.

create table public.citations (
  id uuid primary key default gen_random_uuid(),

  -- The citing end: the practice or proposition the reference appears in.
  source_type public.content_kind not null,
  source_id   uuid not null,
  -- Which comment on the source carried the quotation, when one did. Cascades, because a
  -- citation whose comment is gone has lost the thing it was provenance for.
  source_comment_id uuid references public.comments (id) on delete cascade,

  -- The cited end.
  target_type public.content_kind not null,
  target_id   uuid not null,
  target_comment_id uuid references public.comments (id) on delete cascade,

  -- The passage, copied at the moment of quoting. Stored rather than resolved live for the
  -- same reason a practice stores its transcript rather than a share link: the excerpt has
  -- to survive the target being edited, hidden, or deleted, or the quotation stops being
  -- evidence of anything.
  excerpt text,

  -- Why it is being cited, in the citer's own words. Short on purpose — the argument
  -- belongs in the comment or the proposition, and this is the line that goes in the
  -- "referenced by" block.
  context text,

  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),

  constraint citations_source_kind
    check (source_type in ('practice', 'proposition')),
  constraint citations_target_kind
    check (target_type in ('practice', 'proposition')),

  -- A page does not reference itself. Quoting a practice inside its own discussion is an
  -- ordinary quotation and produces no citation row; if it did, every practice would show
  -- itself in its own "referenced by" block.
  constraint citations_not_self
    check (source_type <> target_type or source_id <> target_id),

  constraint citations_excerpt_length
    check (excerpt is null or length(btrim(excerpt)) between 1 and 2000),
  constraint citations_context_length
    check (context is null or length(btrim(context)) between 1 and 500),

  -- NULLS NOT DISTINCT, which is the whole point of the constraint. Under the default,
  -- every citation with no comment id would be distinct from every other, and the same
  -- practice could cite the same proposition unboundedly. Two different comments quoting
  -- the same target are still two rows, which is correct: each is a separate act.
  constraint citations_no_duplicates
    unique nulls not distinct
      (source_type, source_id, source_comment_id, target_type, target_id, target_comment_id)
);

comment on table public.citations is
  'A practice or proposition referencing another, optionally with the exact comment at '
  'either end. Immutable: no UPDATE grant. The excerpt is stored so a quotation survives '
  'its target being edited or hidden.';
comment on column public.citations.source_comment_id is
  'Which comment on the source carried the quotation. Optional, and what lets a "referenced '
  'by" entry link to the paragraph rather than only to the page.';
comment on column public.citations.excerpt is
  'The passage as it read when it was quoted. A copy, not a pointer — evidence has to '
  'survive the thing it is evidence about.';

-- ── Indexes ─────────────────────────────────────────────────────────────────────────
-- The "referenced by" block is the query this table exists to serve, and it reads
-- backwards: everything pointing at me.

create index citations_target_idx
  on public.citations (target_type, target_id, created_at desc);

create index citations_source_idx
  on public.citations (source_type, source_id);

create index citations_author_idx
  on public.citations (created_by)
  where created_by is not null;

-- ── Endpoint integrity ──────────────────────────────────────────────────────────────
-- A comment id at either end has to belong to the page at that end, or the "referenced by"
-- block will offer a link into a discussion the citation was never part of.
--
-- A trigger rather than a clause in the insert policy, even though the policy could carry
-- it, because this is an integrity rule rather than a permission: it should hold on every
-- row however the row arrived, including rows written by a seeding script under a role
-- that bypasses row level security entirely. SECURITY INVOKER, so the lookups obey the
-- caller's own policies and a citation cannot be pinned to a comment the caller cannot see.

create function private.check_citation_endpoints()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.source_comment_id is not null
     and not exists (
       select 1
         from public.comments c
        where c.id = new.source_comment_id
          and c.parent_type = new.source_type
          and c.parent_id   = new.source_id
     )
  then
    raise exception 'That comment is not part of the discussion doing the citing.'
      using errcode = '23503';
  end if;

  if new.target_comment_id is not null
     and not exists (
       select 1
         from public.comments c
        where c.id = new.target_comment_id
          and c.parent_type = new.target_type
          and c.parent_id   = new.target_id
     )
  then
    raise exception 'That comment is not part of the discussion being cited.'
      using errcode = '23503';
  end if;

  return new;
end;
$$;

comment on function private.check_citation_endpoints() is
  'Requires each optional comment id to belong to the page at its end of the citation. '
  'SECURITY INVOKER, so it cannot pin a citation to a comment the caller cannot see.';

revoke all on function private.check_citation_endpoints() from public;

create trigger citations_check_endpoints
  before insert on public.citations
  for each row
  execute function private.check_citation_endpoints();

-- ── Row level security ──────────────────────────────────────────────────────────────

alter table public.citations enable row level security;

-- Both ends visible, or the row is not. This matters more here than anywhere else on the
-- site: the excerpt column is a verbatim copy of the target's text, so a citation that
-- outlived its target being hidden would republish exactly the passage a moderator
-- removed. The subqueries run under the caller's policies on those tables, so the rule is
-- stated once and follows whatever those policies say.
create policy citations_select_visible
  on public.citations
  for select
  to anon, authenticated
  using (
    (
      (source_type = 'practice'
        and exists (select 1 from public.practices x where x.id = source_id))
      or
      (source_type = 'proposition'
        and exists (select 1 from public.propositions x where x.id = source_id))
    )
    and
    (
      (target_type = 'practice'
        and exists (select 1 from public.practices x where x.id = target_id))
      or
      (target_type = 'proposition'
        and exists (select 1 from public.propositions x where x.id = target_id))
    )
  );

-- Making one: a confirmed, unbanned account, under its own name, with both ends visible
-- and any source comment being one of their own. That last clause is what stops an account
-- attaching its citations to somebody else's comment and putting words in their mouth in
-- the "referenced by" block of a third page.
create policy citations_insert_own
  on public.citations
  for insert
  to authenticated
  with check (
    created_by = (select auth.uid())
    and exists (
      select 1
        from public.profiles p
       where p.id = (select auth.uid())
         and p.confirmed_at is not null
         and not p.is_banned
    )
    and (
      source_comment_id is null
      or exists (
        select 1
          from public.comments c
         where c.id = source_comment_id
           and c.author_id = (select auth.uid())
      )
    )
    and (
      (source_type = 'practice'
        and exists (select 1 from public.practices x where x.id = source_id))
      or
      (source_type = 'proposition'
        and exists (select 1 from public.propositions x where x.id = source_id))
    )
    and (
      (target_type = 'practice'
        and exists (select 1 from public.practices x where x.id = target_id))
      or
      (target_type = 'proposition'
        and exists (select 1 from public.propositions x where x.id = target_id))
    )
  );

-- Withdrawing your own reference, and a moderator removing one. See the header for why
-- this is a real delete and the only one on the site.
create policy citations_delete_own
  on public.citations
  for delete
  to authenticated
  using (created_by = (select auth.uid()));

create policy citations_delete_moderator
  on public.citations
  for delete
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

-- No UPDATE policy, matching the absent grant below. A citation is immutable.

-- ── Grants ──────────────────────────────────────────────────────────────────────────

grant select on public.citations to anon, authenticated;

grant insert (
  source_type, source_id, source_comment_id,
  target_type, target_id, target_comment_id,
  excerpt, context, created_by
) on public.citations to authenticated;

grant delete on public.citations to authenticated;

-- No UPDATE grant of any kind. Immutability is a grant-level fact here, not a policy-level
-- one, so it holds even if somebody later adds a permissive policy without thinking.
