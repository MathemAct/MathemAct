-- One prose box on a network entry instead of two.
--
-- "Why mathematicians should care" asked for something the description was already halfway
-- answering, and two short boxes in a row is where a one-minute form starts to feel like a
-- form. The description absorbs it: the cap goes from 200 to 1000 characters and the prompt
-- now asks for both what the thing is and why the community might care.
--
-- `relevance` is made nullable rather than dropped. Nothing writes it any more and the
-- submission form no longer offers it, but a row that already carries one keeps it: dropping
-- the column would destroy the only copy of text somebody wrote by hand, and a column that is
-- null on every new row costs one field in the CSV and nothing else. Drop it in a later
-- migration if the corpus is confirmed to have none.
--
-- Its length CHECK needs no change. A CHECK evaluates to NULL on a NULL input, and NULL
-- passes -- only an explicit `is not null` would have refused the new rows.

alter table public.network_entries
  drop constraint network_entries_description_length;

alter table public.network_entries
  add constraint network_entries_description_length
    check (length(btrim(description)) between 1 and 1000);

alter table public.network_entries
  alter column relevance drop not null;

comment on column public.network_entries.relevance is
  'Retired 2026-08-21. The submission form asked "why mathematicians should care" as a '
  'separate box; the description now covers it. Nullable, never written, kept for the rows '
  'submitted while it was collected.';
