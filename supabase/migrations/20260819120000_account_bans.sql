-- Banning an account becomes a decision that can be reached, reversed, and explained.
--
-- `ban` and `unban` have been in public.moderate() since 20260815200200, and every insert
-- policy on the site has carried `not p.is_banned` since the table it guards was created. So
-- the *effect* of a ban has always worked. What has not worked is everything around it, and
-- each of the three gaps below is the kind that makes a feature technically present and
-- practically absent.
--
--   1. **The explanation never arrived.** public.moderate() refuses to ban without a reason,
--      writes it to public.moderation_actions — and then stops. The account branch is the one
--      branch that writes no public.moderation_notices row, so the sentence a moderator is
--      forced to write is read by other moderators and by nobody else. It could not have been
--      written even deliberately: `moderation_notices_subject_is_content` restricted
--      `subject_type` to the four content kinds, and an account is not one of them. That is a
--      direct contradiction of the rule the whole moderation design rests on — every decision
--      is explained to the people it is about — and it contradicted it for the single harshest
--      decision a moderator can take. docs/moderation.md claimed the notice existed. It did
--      not.
--
--   2. **A ban could not be lifted.** `unban` is in the enum, in the function, in the
--      TypeScript union and in the list of actions needing a reason. No control anywhere
--      emitted it, and nothing listed banned accounts, so the reversible half of a reversible
--      decision was unreachable. A ban that cannot be lifted is not a ban, it is an erasure
--      with the content left behind.
--
--   3. **Banning twice was a way to notify somebody twice.** Nothing checked the current
--      state, so re-banning a banned account wrote a fresh audit row, and — after this
--      migration — would write a fresh notice and a fresh feed row saying it had just
--      happened. Every content action here already refuses this ("That is already hidden.");
--      the account branch never did.
--
-- What this migration deliberately does **not** do: hide the banned account's posts. Spam is
-- the case that makes it tempting, and a bulk hide is still the wrong shape for this schema —
-- one decision writes one audit row and one notice, and thirty of each in one transaction
-- turns an explanation into a mailshot. Hiding stays per post, and the moderation screen now
-- links from the account to what it posted so that the hides are a short walk rather than a
-- search. See docs/moderation.md.

-- ── 1. A notice may be about an account ─────────────────────────────────────────────
-- Three enum values and one widened CHECK. Every new value is used only inside a plpgsql
-- body below, never in an expression evaluated by this migration, which is what makes adding
-- them in the same file safe: a value added by ALTER TYPE cannot be *used* in the
-- transaction that added it, and a function body is text until something calls it.

alter type public.moderation_outcome add value if not exists 'banned';
alter type public.moderation_outcome add value if not exists 'unbanned';

comment on type public.moderation_outcome is
  'What a moderation decision did, in the words a member reads. Five values: three about a '
  'post, two about an account. Not the same vocabulary as public.moderation_action, which is '
  'the moderator''s.';

-- The recipient of a ban notice is neither of the two roles this type had. They did not write
-- the post that was decided about — there may be no post at all — and they did not flag
-- anything. They are being told because the decision is about their account, which is a third
-- reason to be told and reads differently on the page from both of the others.
alter type public.notice_recipient add value if not exists 'account_holder';

comment on type public.notice_recipient is
  'Why this person is being told: they wrote the post, they flagged it, or it is their '
  'account. One decision reaches each of its recipients as its own row, and each reads '
  'differently on the page.';

-- `account` joins the subjects a notice may be about. `flag` still does not, and that is the
-- distinction the constraint is drawing rather than an omission: a notice is about the thing
-- that was flagged, never about the flag, which is why the flag branch of public.moderate()
-- writes notices naming the subject the flag pointed at.
alter table public.moderation_notices
  drop constraint moderation_notices_subject_is_content;

alter table public.moderation_notices
  add constraint moderation_notices_subject_kind
    check (subject_type in ('report', 'debate', 'comment', 'entry', 'account'));

comment on constraint moderation_notices_subject_kind on public.moderation_notices is
  'What a notice may be about: the four content kinds, and an account. Never a flag — a '
  'notice reports what was decided about the thing flagged, not about the flag.';

comment on table public.moderation_notices is
  'A moderation decision as its subject reads it: outcome, explanation, and what it was '
  'about. One row per recipient. Written only by public.moderate(); readable by the '
  'recipient and by moderators. Never names the moderator or the flagger.';

-- ── 2. Finding the banned ───────────────────────────────────────────────────────────
-- The moderation screen lists everybody currently banned, so that a ban can be lifted by
-- somebody who did not have to remember who it was about. A partial index because the
-- predicate is the query: banned accounts are a handful out of every account there will ever
-- be, and this is the only place in the schema that asks for them as a set.
--
-- Searching by display name is deliberately *not* indexed. It is `ilike '%term%'`, which no
-- btree can serve, and the alternative is pg_trgm on a table whose row count is bounded by
-- the number of mathematicians who sign up. A sequential scan over a few thousand rows on a
-- screen two people use is the right answer; a trigram index would be a cost paid on every
-- profile write for a query run twice a month.

create index profiles_banned_idx
  on public.profiles (display_name)
  where is_banned;

comment on index public.profiles_banned_idx is
  'Everybody currently banned, for the accounts section of /moderate/. Partial: the '
  'predicate is the whole of the query.';

-- ── 3. public.moderate(), with the account branch finished ──────────────────────────
-- Reissued in full from 20260818180000, which is the latest migration that defined it — read
-- that one and not the one that created it, for the reason recorded in CLAUDE.md: a
-- `create or replace` written against a stale copy is how every content write on the site
-- broke on 2026-08-19. The signature is unchanged here, so this is a genuine replacement and
-- not a second overload.
--
-- Everything outside the account branch is identical. Inside it, four changes:
--
--   * **A ban and an unban each check the current state first.** Idempotence is not the
--     point; not telling somebody twice is.
--   * **The audit row is written inside the branch**, as the content and flag branches
--     already do, because the notice needs its id. The shared tail at the foot of the
--     function goes with it — every branch now writes its own row and returns, which is one
--     fewer way for a future action to be added and quietly log the wrong target.
--   * **The account holder is told, in writing.** Same sentence as the log keeps, addressed
--     to them, readable at /account/#decisions.
--   * An erasure still writes no notice and still records no target. There is nobody left to
--     tell — the account is gone by the time the statement commits — and a log row naming the
--     account would preserve exactly the fact somebody asked us to forget.

create or replace function public.moderate(
  p_target_type public.moderation_target,
  p_target_id   uuid,
  p_action      public.moderation_action,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor         uuid := (select auth.uid());
  v_role          text;
  v_banned        boolean;
  v_reason        text := nullif(btrim(coalesce(p_reason, '')), '');
  v_author        uuid;
  v_status        text;
  v_deleted       boolean := false;
  v_kind          public.content_kind;
  v_label         text;
  v_target_role   text;
  v_target_banned boolean;
  v_user          uuid;
  v_audit         uuid;
  v_outcome       public.moderation_outcome;
  v_flag          record;
  v_flag_audit    uuid;
  v_subject       public.moderation_target;
  v_subject_id    uuid;
begin
  -- ── Who is asking ─────────────────────────────────────────────────────────────────
  -- auth.uid(), not current_user. A DEFINER function that asked current_user would see its
  -- own owner on every request; auth.uid() is a JWT claim and reads the same here as in any
  -- policy. That is what makes the authorisation below real.

  if v_actor is null then
    raise exception 'Moderation needs a signed-in account.'
      using errcode = '42501';
  end if;

  select p.role, p.is_banned
    into v_role, v_banned
    from public.profiles p
   where p.id = v_actor;

  if v_role is null or v_role not in ('moderator', 'admin') or v_banned then
    raise exception 'This account cannot take moderation actions.'
      using errcode = '42501';
  end if;

  -- ── The retired actions ───────────────────────────────────────────────────────────

  if p_action in ('publish', 'request_changes', 'promote') then
    raise exception
      'Posts are published when they are written; there is nothing to approve, send back or promote. What is left to decide is a flag: hide what it named, or leave it up. Either way, say why.'
      using errcode = '0A000';
  end if;

  -- ── The explanation ───────────────────────────────────────────────────────────────
  -- Everything but carrying out an erasure request. The same rule is a CHECK on
  -- public.moderation_actions; this copy exists so the refusal arrives as a sentence rather
  -- than as a constraint name.

  if p_action <> 'erase_account' and v_reason is null then
    raise exception
      'Every decision here needs an explanation. It is shown to whoever wrote the post and to whoever flagged it, so write it to them: one sentence saying what the problem is, or that there is not one.'
      using errcode = '23514';
  end if;

  -- ── Content: report, debate, comment, entry ───────────────────────────────────────

  if p_target_type in ('report', 'debate', 'comment', 'entry') then

    if p_target_type = 'report' then
      select x.author_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.reports x
       where x.id = p_target_id;

    elsif p_target_type = 'debate' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.debates x
       where x.id = p_target_id;

    elsif p_target_type = 'comment' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.comments x
       where x.id = p_target_id;

    else
      select x.submitter_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.network_entries x
       where x.id = p_target_id;
    end if;

    if not found then
      raise exception 'That is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_deleted then
      raise exception
        'Its author deleted that already. There is nothing left to hide; close the flag against it instead.'
        using errcode = '23514';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own post. Another moderator has to decide it — that has not changed, and it is the one shortcut that would make the record worthless.'
        using errcode = '42501';
    end if;

    if p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That is already hidden.'
          using errcode = '23514';
      end if;

      if p_target_type = 'report' then
        update public.reports set status = 'hidden' where id = p_target_id;
      elsif p_target_type = 'debate' then
        update public.debates set status = 'hidden', activated_at = null where id = p_target_id;
      elsif p_target_type = 'comment' then
        update public.comments set status = 'hidden' where id = p_target_id;
      else
        update public.network_entries set status = 'hidden' where id = p_target_id;
      end if;

      v_outcome := 'hidden';

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That is not hidden.'
          using errcode = '23514';
      end if;

      if p_target_type = 'report' then
        update public.reports set status = 'published' where id = p_target_id;
      elsif p_target_type = 'debate' then
        update public.debates set status = 'active', activated_at = now() where id = p_target_id;
      elsif p_target_type = 'comment' then
        update public.comments set status = 'published' where id = p_target_id;
      else
        update public.network_entries set status = 'published' where id = p_target_id;
      end if;

      v_outcome := 'restored';

    else
      raise exception 'That action does not apply to a post.'
        using errcode = '23514';
    end if;

    insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
    values (v_actor, p_action, p_target_type, p_target_id, v_reason)
    returning id into v_audit;

    v_label := private.activity_label(p_target_type, p_target_id);

    if v_author is not null then
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, p_target_type, p_target_id, v_label, v_outcome, v_reason, v_author, 'author'
      );
    end if;

    -- ── The flags that named it ─────────────────────────────────────────────────────
    -- Hiding answers every open flag against this row at once, each closure its own audit
    -- row and its own notice. Only the three flaggable kinds: public.flags.subject_type is
    -- public.content_kind, which has no `entry`.

    if p_action = 'hide' and p_target_type in ('report', 'debate', 'comment') then
      v_kind := case p_target_type
                  when 'report'  then 'report'::public.content_kind
                  when 'debate'  then 'debate'::public.content_kind
                  when 'comment' then 'comment'::public.content_kind
                end;

      for v_flag in
        select f.id, f.flagger_id
          from public.flags f
         where f.subject_type = v_kind
           and f.subject_id = p_target_id
           and f.status = 'open'
         order by f.created_at
      loop
        update public.flags
           set status = 'actioned', resolved_at = now(), resolved_by = v_actor
         where id = v_flag.id;

        insert into public.moderation_actions
          (actor_id, action, target_type, target_id, reason)
        values (v_actor, 'resolve_flag', 'flag', v_flag.id, v_reason)
        returning id into v_flag_audit;

        if v_flag.flagger_id is not null
           and v_flag.flagger_id is distinct from v_author
           and v_flag.flagger_id is distinct from v_actor then
          insert into public.moderation_notices (
            action_id, subject_type, subject_id, label, outcome, explanation,
            recipient_id, recipient_role
          )
          values (
            v_flag_audit, p_target_type, p_target_id, v_label, 'hidden', v_reason,
            v_flag.flagger_id, 'flagger'
          );
        end if;
      end loop;
    end if;

    return v_audit;

  -- ── Flags ─────────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'flag' then
    select f.status::text, f.flagger_id, private.as_target(f.subject_type), f.subject_id
      into v_status, v_user, v_subject, v_subject_id
      from public.flags f
     where f.id = p_target_id;

    if not found then
      raise exception 'That flag is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_status <> 'open' then
      raise exception 'That flag has already been dealt with.'
        using errcode = '23514';
    end if;

    if p_action not in ('resolve_flag', 'dismiss_flag') then
      raise exception 'That action does not apply to a flag.'
        using errcode = '23514';
    end if;

    if v_user is not distinct from v_actor then
      raise exception
        'This is your own flag. Another moderator has to answer it.'
        using errcode = '42501';
    end if;

    if v_subject = 'report' then
      select x.author_id, x.status::text, x.deleted_at is not null
        into v_author, v_status, v_deleted
        from public.reports x where x.id = v_subject_id;
    elsif v_subject = 'debate' then
      select x.author_id, x.status::text
        into v_author, v_status
        from public.debates x where x.id = v_subject_id;
    else
      select x.author_id, x.status::text
        into v_author, v_status
        from public.comments x where x.id = v_subject_id;
    end if;

    if p_action = 'resolve_flag' and coalesce(v_status, 'gone') not in ('hidden', 'gone')
       and not v_deleted then
      raise exception
        'What this flag named is still on the site. Hide it — that closes this flag and every other one against it — or dismiss the flag and say why it stays.'
        using errcode = '23514';
    end if;

    update public.flags
       set status = case when p_action = 'resolve_flag'
                         then 'actioned'::public.flag_status
                         else 'dismissed'::public.flag_status
                    end,
           resolved_at = now(),
           resolved_by = v_actor
     where id = p_target_id;

    insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
    values (v_actor, p_action, 'flag', p_target_id, v_reason)
    returning id into v_audit;

    v_outcome := case when p_action = 'resolve_flag' then 'hidden' else 'kept' end;
    v_label   := private.activity_label(v_subject, v_subject_id);

    insert into public.moderation_notices (
      action_id, subject_type, subject_id, label, outcome, explanation,
      recipient_id, recipient_role
    )
    values (
      v_audit, v_subject, v_subject_id, v_label, v_outcome, v_reason, v_user, 'flagger'
    );

    if p_action = 'dismiss_flag'
       and v_author is not null
       and v_author is distinct from v_user
       and v_author is distinct from v_actor then
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, v_subject, v_subject_id, v_label, 'kept', v_reason, v_author, 'author'
      );
    end if;

    return v_audit;

  -- ── Accounts ──────────────────────────────────────────────────────────────────────
  -- A ban is the one decision here that is not about a post. It is for an account whose
  -- behaviour is the problem rather than any one thing it wrote — spam, and sustained
  -- hostility — and it is reversible, which is the whole difference between it and an
  -- erasure.
  --
  -- What it does: sets public.profiles.is_banned, which every insert policy on the site
  -- reads. Posting, commenting, rating, confirming, flagging and citing all stop. Reading
  -- does not, editing a profile does not, and asking to be erased does not — a ban is not a
  -- way to strand somebody with an account they cannot leave.
  --
  -- What it does not do: touch anything the account posted. Their reports stay in the corpus
  -- and their comments stay in their threads, because a ban is a judgement about a person's
  -- conduct and a hide is a judgement about a post, and collapsing the two would mean
  -- removing content nobody had read against the rules in docs/moderation.md.

  elsif p_target_type = 'account' then

    if p_action in ('ban', 'unban') then
      if p_target_id = v_actor then
        raise exception 'An account cannot ban itself.'
          using errcode = '42501';
      end if;

      select p.role, p.is_banned
        into v_target_role, v_target_banned
        from public.profiles p
       where p.id = p_target_id;

      if not found then
        raise exception 'There is no such account.'
          using errcode = '23503';
      end if;

      if v_target_role in ('moderator', 'admin') then
        raise exception
          'Accounts with moderation standing are not banned from this screen. That change needs direct database access, so one compromised session cannot disable the people who would notice.'
          using errcode = '42501';
      end if;

      -- Already in the state being asked for. Refused rather than repeated, because the
      -- effect is idempotent and the notification is not: a second ban would write a second
      -- audit row, a second notice, and a second feed row telling somebody their account had
      -- just been suspended when nothing had changed since the last time they were told.
      if p_action = 'ban' and v_target_banned then
        raise exception 'That account is already banned.'
          using errcode = '23514';
      end if;

      if p_action = 'unban' and not v_target_banned then
        raise exception 'That account is not banned.'
          using errcode = '23514';
      end if;

      update public.profiles
         set is_banned = (p_action = 'ban')
       where id = p_target_id;

      insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
      values (v_actor, p_action, 'account', p_target_id, v_reason)
      returning id into v_audit;

      -- Cast rather than left to the assignment. Both branches of an unadorned CASE are
      -- `unknown`, so it resolves to `text` and reaches the enum through an I/O coercion that
      -- happens to be permitted — which is a thing to rely on in a query somebody wrote once,
      -- not in the one function every moderation decision goes through.
      v_outcome := case when p_action = 'ban'
                        then 'banned'::public.moderation_outcome
                        else 'unbanned'::public.moderation_outcome
                   end;

      -- The account holder reads the same sentence the log keeps. `label` stays null: the
      -- other notices carry the heading of the post they are about, and the only heading an
      -- account has is the name of the person reading it.
      --
      -- `subject_id` is the account, and so is `recipient_id`. That is redundant here and
      -- deliberate — the row says what it is about and who it is for, in the same shape as
      -- every other notice, so the page rendering it needs no special case for whose it is.
      insert into public.moderation_notices (
        action_id, subject_type, subject_id, label, outcome, explanation,
        recipient_id, recipient_role
      )
      values (
        v_audit, 'account', p_target_id, null, v_outcome, v_reason,
        p_target_id, 'account_holder'
      );

      return v_audit;

    elsif p_action = 'erase_account' then
      -- Admins only. A ban is reversible and a content decision; this is neither.
      if v_role <> 'admin' then
        raise exception 'Erasing an account is an admin action.'
          using errcode = '42501';
      end if;

      -- p_target_id is the *request* id, not the person. The only way to reach this branch
      -- is a pending row that the account holder wrote for themselves, so an admin cannot
      -- use this to remove somebody who has not asked.
      select d.user_id
        into v_user
        from public.deletion_requests d
       where d.id = p_target_id
         and d.status = 'pending';

      if not found then
        raise exception 'That erasure request is no longer pending. Reload the page.'
          using errcode = '23503';
      end if;

      if v_user = v_actor then
        raise exception
          'Erasing your own account from here would take the record of who did it with it. Ask another admin.'
          using errcode = '42501';
      end if;

      -- The audit row goes first, and it records no target. Keeping the user id would
      -- preserve, in a table designed never to be edited, exactly the fact somebody asked us
      -- to forget — and writing it after the delete would fail, because the actor's own
      -- foreign key is fine but the row has nothing left to point at.
      insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
      values (v_actor, 'erase_account', 'account', null, v_reason)
      returning id into v_audit;

      -- The whole erasure, in one statement, because every rule about what survives is
      -- already written into the foreign keys — including public.moderation_notices, which
      -- cascades: a message addressed to somebody who no longer exists is not a record, it
      -- is an undeliverable letter.
      delete from auth.users u where u.id = v_user;

      return v_audit;

    else
      raise exception 'That action does not apply to an account.'
        using errcode = '23514';
    end if;

  else
    -- A value was added to public.moderation_target without a branch here. Refusing is the
    -- only safe answer: the alternative is an action that happens and is never logged.
    raise exception 'public.moderate() has no rule for target %', p_target_type
      using errcode = '0A000';
  end if;
end;
$$;

comment on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) is
  'The only audited route for a moderation decision: answer a flag, hide or restore a post, '
  'ban or readmit an account, or carry out an erasure request. Every action except the '
  'erasure carries an explanation, which reaches the people it is about as '
  'public.moderation_notices. Every branch writes its own audit row and returns. SECURITY '
  'DEFINER so it can write rows the caller cannot; authorises on auth.uid(), which is what '
  'makes that safe.';
