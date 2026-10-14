-- public.tags and public.practice_tags — what a practice is about.
--
-- Seeded with the top-level arXiv mathematics categories, because that is the vocabulary
-- this audience already sorts itself by: a number theorist looking for accounts relevant to
-- them will look for math.NT before they look for anything we invent.
--
-- Generic on purpose
-- ------------------
-- `scheme` is what keeps this table from being an arXiv table with delusions. MSC codes are
-- named in the content model alongside arXiv categories, and a corpus about tool use will
-- eventually want tags that are neither -- "Lean 4", "undergraduate teaching" -- which are
-- about the practice rather than about the mathematics. Those are a different scheme in the
-- same table, not a second table, and not a free-text field: a controlled vocabulary is
-- what makes filtering mean anything, and the moment tags are free text the corpus grows
-- eleven spellings of "formalisation".
--
-- Curated, not user-created. There is no INSERT grant on this table for any browser role.
-- Adding a tag is a migration or a moderator with a database session, which is the correct
-- amount of friction for a decision that changes how every past practice can be found.

create table public.tags (
  id uuid primary key default gen_random_uuid(),

  -- 'arxiv' today. 'msc' and 'topic' are the anticipated others; the CHECK is here so that
  -- adding one is a deliberate migration rather than a typo that creates a scheme of one.
  scheme text not null,

  -- The identifier within the scheme: 'math.NT' for arXiv, '11N05' for MSC. This is what
  -- appears in URLs and in the export, so it is the stable public handle rather than the
  -- uuid.
  code text not null,

  label text not null,

  -- Retired rather than deleted. A tag that has been used cannot be removed without
  -- rewriting history on the practices that carry it, so the way to withdraw one is to
  -- stop offering it in the form while existing rows keep resolving.
  is_active boolean not null default true,

  sort_order integer,

  created_at timestamptz not null default now(),

  constraint tags_scheme_valid check (scheme in ('arxiv', 'msc', 'topic')),
  constraint tags_code_length  check (length(btrim(code)) between 1 and 40),
  constraint tags_label_length check (length(btrim(label)) between 1 and 120),
  constraint tags_unique_in_scheme unique (scheme, code)
);

comment on table public.tags is
  'Controlled tag vocabulary. Curated: no browser role holds INSERT, UPDATE or DELETE.';
comment on column public.tags.code is
  'The public handle, used in URLs and the export. Stable; the uuid is an implementation '
  'detail.';
comment on column public.tags.is_active is
  'False retires a tag from the form without breaking practices that already carry it.';

create index tags_scheme_idx on public.tags (scheme, sort_order, code);

-- ── The arXiv mathematics categories ────────────────────────────────────────────────
-- All 32 subject classes of the math archive, with arXiv's own names. sort_order follows
-- the code alphabetically, which is how arXiv itself lists them and therefore how this
-- audience expects to scan them.

insert into public.tags (scheme, code, label, sort_order) values
  ('arxiv', 'math.AC', 'Commutative Algebra',          10),
  ('arxiv', 'math.AG', 'Algebraic Geometry',           20),
  ('arxiv', 'math.AP', 'Analysis of PDEs',             30),
  ('arxiv', 'math.AT', 'Algebraic Topology',           40),
  ('arxiv', 'math.CA', 'Classical Analysis and ODEs',  50),
  ('arxiv', 'math.CO', 'Combinatorics',                60),
  ('arxiv', 'math.CT', 'Category Theory',              70),
  ('arxiv', 'math.CV', 'Complex Variables',            80),
  ('arxiv', 'math.DG', 'Differential Geometry',        90),
  ('arxiv', 'math.DS', 'Dynamical Systems',           100),
  ('arxiv', 'math.FA', 'Functional Analysis',         110),
  ('arxiv', 'math.GM', 'General Mathematics',         120),
  ('arxiv', 'math.GN', 'General Topology',            130),
  ('arxiv', 'math.GR', 'Group Theory',                140),
  ('arxiv', 'math.GT', 'Geometric Topology',          150),
  ('arxiv', 'math.HO', 'History and Overview',        160),
  ('arxiv', 'math.IT', 'Information Theory',          170),
  ('arxiv', 'math.KT', 'K-Theory and Homology',       180),
  ('arxiv', 'math.LO', 'Logic',                       190),
  ('arxiv', 'math.MG', 'Metric Geometry',             200),
  ('arxiv', 'math.MP', 'Mathematical Physics',        210),
  ('arxiv', 'math.NA', 'Numerical Analysis',          220),
  ('arxiv', 'math.NT', 'Number Theory',               230),
  ('arxiv', 'math.OA', 'Operator Algebras',           240),
  ('arxiv', 'math.OC', 'Optimization and Control',    250),
  ('arxiv', 'math.PR', 'Probability',                 260),
  ('arxiv', 'math.QA', 'Quantum Algebra',             270),
  ('arxiv', 'math.RA', 'Rings and Algebras',          280),
  ('arxiv', 'math.RT', 'Representation Theory',       290),
  ('arxiv', 'math.SG', 'Symplectic Geometry',         300),
  ('arxiv', 'math.SP', 'Spectral Theory',             310),
  ('arxiv', 'math.ST', 'Statistics Theory',           320);

alter table public.tags enable row level security;

-- The vocabulary is public. There is no write policy at all, matching the absent grants:
-- a policy nobody can reach is a policy somebody will one day mistake for permission.
create policy tags_select_all
  on public.tags
  for select
  to anon, authenticated
  using (true);

grant select on public.tags to anon, authenticated;

-- ── practice_tags ───────────────────────────────────────────────────────────────────

create table public.practice_tags (
  practice_id uuid not null references public.practices (id) on delete cascade,
  tag_id      uuid not null references public.tags (id) on delete restrict,

  created_at timestamptz not null default now(),

  primary key (practice_id, tag_id)
);

comment on table public.practice_tags is
  'Which tags a practice carries. RESTRICT on tag_id: retiring a tag is is_active = false, '
  'never a delete that would silently untag existing work.';

create index practice_tags_tag_idx on public.practice_tags (tag_id);

alter table public.practice_tags enable row level security;

-- As with practice_tools, visibility defers entirely to the parent practice. The subquery
-- runs under the caller's own row level security, so the rule lives in one place.
create policy practice_tags_select_with_parent
  on public.practice_tags
  for select
  to anon, authenticated
  using (
    exists (select 1 from public.practices p where p.id = practice_id)
  );

create policy practice_tags_insert_own_pending
  on public.practice_tags
  for insert
  to authenticated
  with check (
    exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.author_id = (select auth.uid())
         and p.status = 'pending'
         and p.deleted_at is null
    )
    -- A retired tag cannot be added to new work, while practices already carrying it keep
    -- resolving. That is the whole reason is_active exists.
    and exists (
      select 1 from public.tags t where t.id = tag_id and t.is_active
    )
  );

create policy practice_tags_delete_own_pending
  on public.practice_tags
  for delete
  to authenticated
  using (
    exists (
      select 1
        from public.practices p
       where p.id = practice_id
         and p.author_id = (select auth.uid())
         and p.status = 'pending'
         and p.deleted_at is null
    )
  );

-- No UPDATE policy and no UPDATE grant. The table is two foreign keys; changing a tag is
-- a delete and an insert, and an UPDATE path would only be a second way to write the same
-- thing with its own policy to get wrong.

grant select on public.practice_tags to anon, authenticated;
grant insert (practice_id, tag_id) on public.practice_tags to authenticated;
grant delete on public.practice_tags to authenticated;
