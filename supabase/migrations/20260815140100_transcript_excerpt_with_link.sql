-- A transcript link may not stand alone.
--
-- CLAUDE.md's content model is explicit about this and the schema was not enforcing it:
-- "the pasted excerpt is the canonical artifact and is stored in our database. Share links
-- expire, get revoked, and may breach provider terms, so they are never the only record."
--
-- A practice carrying a link and no excerpt is a practice whose evidence lives on somebody
-- else's server, under terms they can change, for as long as they feel like hosting it.
-- The corpus is meant to be downloadable and archivable in full; a row like that is a hole
-- in it that nobody notices until the link is dead and the account is unverifiable.
--
-- Note the asymmetry, which is the whole rule: an excerpt with no link is fine and common.
-- It is the link without an excerpt that is refused.
--
-- Safe to add without a backfill: there are no practices yet.

alter table public.practices
  add constraint practices_link_needs_excerpt
  check (transcript_url is null or transcript_excerpt is not null);

comment on constraint practices_link_needs_excerpt on public.practices is
  'A share link is supplementary and never the only record. Links expire, are revoked, and '
  'may breach provider terms; the excerpt is ours and is what the export carries.';
