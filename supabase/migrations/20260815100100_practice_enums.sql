-- The controlled vocabularies a practice is written in.
--
-- Enums rather than text with a CHECK, and rather than lookup tables, because these are
-- the vocabulary of the reporting standard rather than data. Structure beats
-- expressiveness here: every field that constrains what an author can write is what makes
-- the corpus comparable five years from now instead of a pile of prose. A lookup table
-- invites rows to be added by whoever is closest to the admin UI; an enum makes widening
-- the vocabulary a migration with a comment saying why, which is the correct amount of
-- friction for a decision that changes what every past account means.
--
-- Adding a value later is `alter type ... add value`, which is cheap. Removing or renaming
-- one is not, and that asymmetry is the point.
--
-- These names are the wire format. src/lib/status.ts already spells the outcomes
-- worked / partial / failed, and the values below match it exactly so that nothing has to
-- translate between the database, the form, the JSON export, and the tombstone.

-- ── Area ────────────────────────────────────────────────────────────────────────────
-- What kind of work this was, per CLAUDE.md's content model.

create type public.practice_area as enum (
  'research',
  'learning',
  'teaching',
  'writing',
  'other'
);

comment on type public.practice_area is
  'What kind of mathematical work the practice describes.';

-- ── Task type ───────────────────────────────────────────────────────────────────────
-- What the tool was actually asked to do. This is the axis the corpus will most often be
-- grouped by: "how well does this work for proof checking" is a question the schema has to
-- be able to answer without reading every account.

create type public.practice_task_type as enum (
  'literature_search',
  'conjecture_generation',
  'proof_drafting',
  'proof_checking',
  'formalisation',
  'computation',
  'exposition',
  'translation',
  'referee_work',
  'other'
);

comment on type public.practice_task_type is
  'What the tool was asked to do. The primary axis for grouping the corpus.';

-- ── Outcome ─────────────────────────────────────────────────────────────────────────
-- Three values, and 'failed' is not a lesser one. A corpus of only successes is worthless
-- and reads as advertising; failure modes are precisely what nobody publishes and what
-- makes this collection worth having. Nothing anywhere -- schema, ordering, or interface --
-- is permitted to treat this value as second class.

create type public.practice_outcome as enum (
  'worked',
  'partial',
  'failed'
);

comment on type public.practice_outcome is
  'What the author reports happened. Matches OUTCOMES in src/lib/status.ts. A failure is a '
  'first-class contribution, not a lesser one.';

-- ── Content status ──────────────────────────────────────────────────────────────────
-- Shared by every user-content table that follows: practices now, comments and
-- propositions later. Moderation is volunteer-run, so nothing ships to real users without
-- a working hide path, and that path is this column.

create type public.content_status as enum (
  'pending',
  'published',
  'hidden'
);

comment on type public.content_status is
  'Moderation state for any user-content table. New content starts pending; only a '
  'moderator moves it.';

-- ── Confirmation verdict ────────────────────────────────────────────────────────────
-- The prompt for this work names four enums and leaves the verdict's representation open.
-- It is an enum too, for the same reason as the others: it is a two-value vocabulary that
-- drives the tombstone on every listing page, and a stray 'still works' with a space in it
-- would silently render as unverified rather than as an error.

create type public.confirmation_verdict as enum (
  'still_works',
  'no_longer_works'
);

comment on type public.confirmation_verdict is
  'A reader''s report on whether a practice still reproduces. Drives the tombstone.';
