-- "Request changes" needs somewhere for the changes to be requested.
--
-- The moderation screen offers four decisions on a pending practice: publish it, hide it,
-- unhide it, or ask the author to change something. The fourth is the only one that has to
-- reach a person, and there is nowhere on this site to put a message to somebody:
--
--   * We hold no email address that any of our code may read, by design, so there is no
--     mail to send and no place to send it from — a static site has no server.
--   * A comment on the pending practice would be visible to its author and to moderators
--     today, and to everybody the moment the practice is published. A private note that
--     becomes public on acceptance is a trap.
--   * A message table would be a second inbox nobody checks.
--
-- So the note lives on the row it is about, where the author already has read access
-- through practices_select_own, and is shown to them under "Your submissions" on their
-- account page. One note at a time: it is the current state of the review, not a
-- correspondence. The history of who asked for what is in public.moderation_actions.
--
-- No UPDATE grant is added for these columns. The moderation screen writes them through
-- public.moderate(), which runs as the table owner, so a browser role needs no privilege on
-- them in either direction. An author who tried to clear the note gets a permission error
-- rather than a silent no-op, which is the right way round for a column whose whole purpose
-- is to say something the author might prefer gone.
--
-- Reading is a different matter and worth being exact about. `grant select on public.practices
-- to anon, authenticated` is table-wide and covers columns added later, so these three are
-- readable by anyone who can read the row. That is not a leak, because the only rows carrying
-- a note are pending or hidden ones — which row level security shows to their author and to
-- moderators and to nobody else — and publishing clears the note in the same statement that
-- publishes. Two things follow for anyone changing this later: `request_changes` must keep
-- refusing anything that is not pending, and the corpus query in src/lib/practices.ts must
-- keep naming its columns explicitly rather than selecting `*`.

alter table public.practices
  add column moderation_note    text,
  add column moderation_note_at timestamptz,
  -- SET NULL, like every other reference to a person here. If the moderator who wrote the
  -- note erases their account, the note stands without their name on it.
  add column moderation_note_by uuid references public.profiles (id) on delete set null;

alter table public.practices
  -- The note and its date move together. A note with no date cannot be shown as "asked for
  -- on the 14th", and a date with no note is a review that said nothing.
  add constraint practices_moderation_note_dated
    check ((moderation_note is null) = (moderation_note_at is null)),

  -- The same cap as moderation_actions.reason, because it is the same sentence written
  -- once and stored twice: once for the author, once for the log.
  add constraint practices_moderation_note_length
    check (moderation_note is null or length(btrim(moderation_note)) between 1 and 1000);

comment on column public.practices.moderation_note is
  'The current change request from a moderator, written for the author and shown to them on '
  'their account page. One at a time; the history is in public.moderation_actions.';
comment on column public.practices.moderation_note_at is
  'When the change was asked for. Shown to the author so an old request is visibly old.';
comment on column public.practices.moderation_note_by is
  'Which moderator asked. Never shown to the author — the note is the answer, not the '
  'person. Kept so the queue can show who has already looked at something.';

-- The queue query is "pending, oldest first", which practices_pending_idx already serves.
-- What it does not answer is "pending and already sent back", which is the set a moderator
-- should skip past: those are waiting on the author, not on a moderator.
create index practices_awaiting_author_idx
  on public.practices (moderation_note_at)
  where status = 'pending' and moderation_note_at is not null and deleted_at is null;
