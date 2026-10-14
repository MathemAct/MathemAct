-- The edit window on a debate contribution: 24 hours, and closed as soon as anyone endorses it.
--
-- **In the guard, not in a policy, and that is not a stylistic preference.** Permissive row
-- level security policies on one command are OR'd together — both their USING and their WITH
-- CHECK clauses. `public.comments` has two permissive UPDATE policies for authors:
-- `comments_update_own` and `comments_soft_delete_own`. The delete policy has to permit an
-- update at any age, because an author may delete a contribution they wrote last year. So a
-- window written into the edit policy is granted straight back by the delete policy: an
-- ordinary edit satisfies the delete policy's USING (it is theirs and undeleted) and then
-- satisfies the edit policy's WITH CHECK, and the window withholds nothing at all while
-- reading in review exactly like one that works. A BEFORE UPDATE trigger is the only single
-- choke point an update has. This is recorded in CLAUDE.md and the debates window inherits it
-- unchanged.
--
-- Why closing on the first endorsement is the same rule as closing on the first reply
-- -----------------------------------------------------------------------------------
-- A report comment's window closes when somebody replies to it, because they replied to the
-- sentence in front of them. An endorsement is the debates equivalent and is a stronger claim:
-- somebody has said "this also captures my view" about a specific piece of reasoning. Letting
-- the author then rewrite that reasoning would reassign a stranger's agreement to an argument
-- they never read, and unlike a reply there is no visible follow-up in which the change could
-- be noticed.
--
-- **The whole function is reissued rather than patched**, per the standing rule for this
-- project's guards. The version replaced here is the one from 20260817130000, which is itself
-- 20260815200300's body — the one with the moderator branch removed, because
-- public.moderate() is the only route to `status`. Three things change and nothing else does:
--
--   * `agreement_score`, `superseded_by` and `endorsed_at` join the frozen columns.
--   * The early-close test branches on the subject type.
--   * Nothing whatsoever in the delete path.
--
-- `create or replace` is safe here because the signature is unchanged. It takes no arguments
-- and never has; the hazard recorded in 20260819090000 is a signature change, which this is
-- not.

-- Where the endorsement answer comes from
-- ---------------------------------------
-- Not from public.comment_endorsements, and not from a helper function either. It comes from
-- `public.comments.endorsed_at`, stamped by a DEFINER trigger in 20260821120200. The two routes
-- this file does **not** take are worth recording, because one of them fails silently in the
-- dangerous direction:
--
--   An `exists` on public.comment_endorsements inside this guard would run under the caller's
--   own policies, because the guard is INVOKER. That table is readable only by the endorser,
--   and the caller here is the contribution's *author* — who cannot endorse their own
--   contribution and therefore owns none of its endorsement rows. The subquery would return
--   zero however many endorsements exist, so the window would read as closed in the source
--   while being open in production.
--
--   Delegating that read to a SECURITY DEFINER helper in `private` fails differently and
--   louder: `authenticated` holds no USAGE on the private schema — 20260813200000 revoked it
--   and 002_exposure.test.sql asserts it — so the call itself is refused with 42501 and every
--   legitimate edit becomes a permission error.
--
-- Reading a column on the row already being updated has neither problem, costs nothing, and is
-- the same shape as `public.reports.answered_at`.

-- ── The guard ───────────────────────────────────────────────────────────────────────
-- SECURITY INVOKER, and load-bearing: inside a DEFINER function `current_user` is the
-- function's owner, so the trusted check below would pass on every browser request and the
-- guard would revert nothing while reading exactly like one that works. This project has paid
-- for that once.

create or replace function private.protect_comment_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.comments'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for absolutely everyone. Moving a comment to another discussion, or into
  -- another position in this one, would strand the replies under it.
  new.id          := old.id;
  new.parent_type := old.parent_type;
  new.parent_id   := old.parent_id;
  new.in_reply_to := old.in_reply_to;
  new.created_at  := old.created_at;

  -- The two columns this rebuild added, frozen here as well as ungranted. A contribution's
  -- position is a fact about the moment it was written, and a caller who could move it could
  -- file their reasoning under a group they never held. `superseded_by` is written only by
  -- private.supersede_previous_contribution(), which arrives as the owner and is let through
  -- by the trusted check above.
  new.agreement_score := old.agreement_score;
  new.superseded_by   := old.superseded_by;
  new.endorsed_at     := old.endorsed_at;

  -- Hiding preserves the text and the name, which is what makes it reviewable and
  -- reversible. It is public.moderate()'s to set and nobody else's.
  new.status := old.status;

  if old.deleted_at is not null then
    -- Already gone. Nothing about a deleted comment changes again, including undeleting
    -- it: the body it had is not stored anywhere to restore.
    new.deleted_at := old.deleted_at;
    new.author_id  := old.author_id;
    new.body       := old.body;
    return new;
  end if;

  if new.deleted_at is not null then
    -- The deletion itself, and the only place these two assignments happen. The node
    -- survives so the replies under it still read; the text and the name do not.
    --
    -- Untouched by this migration. A contribution stays soft-deletable at any age, endorsed
    -- or not: its score is part of the distribution's provenance and a hard delete would take
    -- a count with it, but the words are the author's to withdraw.
    new.body      := '';
    new.author_id := null;
    return new;
  end if;

  -- An ordinary edit from here down.
  new.author_id := old.author_id;

  if new.body is distinct from old.body then
    -- Twenty-four hours, and the number is not arbitrary. Comments carry TeX, TeX is
    -- rendered at build time, and the build is nightly — so an author's first sight of
    -- their own formula rendered is up to a day after they wrote it. A window shorter than
    -- one build cycle would mean nobody could ever fix a formula that came out wrong.
    --
    -- The same 24 hours on both kinds. What differs is what closes it early.
    if old.created_at <= now() - interval '24 hours' then
      raise exception
        'The edit window on a comment is 24 hours, and this one has passed. Post a '
        'follow-up comment instead — the thread keeps both.'
        using errcode = '23514';
    end if;

    if old.parent_type = 'debate' then
      -- A debate contribution: closed by the first endorsement. Somebody has said this
      -- reasoning is theirs too, and rewriting it now would put words they never read under
      -- their agreement. There is no reply thread here in which the change could be seen —
      -- contributions on debates are flat — so the earlier text has no witness other than
      -- this rule.
      --
      -- Read off the row rather than out of public.comment_endorsements. See the note at the
      -- top of this file: this caller is not the endorser, so an `exists` here would return
      -- false however many endorsements existed and the window would be decorative.
      if old.endorsed_at is not null then
        raise exception
          'Somebody has said this contribution captures their view, so its text is fixed. '
          'Answer the debate again and write a new contribution instead — this one stays '
          'where it is, and the two are linked.'
          using errcode = '23514';
      end if;
    else
      -- A report comment: unchanged. Closed by the first reply, because people replied to
      -- the sentence in front of them and rewriting it afterwards makes their reply answer
      -- something they never read.
      if exists (select 1 from public.comments r where r.in_reply_to = old.id) then
        raise exception
          'This comment has replies, so its text is fixed. Post a follow-up instead.'
          using errcode = '23514';
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function private.protect_comment_columns() is
  'Reverts writes the caller does not own, performs the soft-delete erasure, freezes the '
  'position and supersession columns, and enforces the 24 hour edit window — closed by the '
  'first endorsement on a debate contribution and by the first reply on a report comment. '
  'SECURITY INVOKER; the window is here rather than in a policy because permissive policies '
  'are OR''d and the delete policy would grant round it.';

revoke all on function private.protect_comment_columns() from public;

-- The trigger itself is not recreated. `comments_protect_columns` from 20260815180000 already
-- points at this name, and `create or replace` has replaced the body under it.
