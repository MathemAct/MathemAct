-- Renames the site's vocabulary throughout the schema:
--
--   practice     -> report          public.practices and everything hanging off it
--   proposition  -> debate
--   resource     -> network entry   the collection is "the network"; one row is an entry
--   report       -> flag            the moderation control, renamed to free the word
--
-- Why rename the schema rather than only the interface. The schema is the corpus's public
-- surface: it is what scripts/export.mjs selects from, what the CSV column headers are named
-- after, and what anyone who downloads the dataset reads. Two names for one table would be a
-- permanent tax on every reader of it, so the database learns the new words too.
--
-- The order below is the whole trick. "report" is already taken when this migration starts —
-- it is the moderation control — so the incumbent moves out of the way first and practices
-- only then moves in. Every step that touches a name does it in that order: the tables, the
-- enum labels, the object names, and the private.settings keys. Getting it the wrong way
-- round fails loudly on a duplicate name rather than quietly on the wrong table, which is
-- the one mercy of doing it this way.
--
-- What does not need rewriting, and why. Views, RLS policies and CHECK constraints store
-- parsed expressions, so a reference to a renamed table, column or enum label follows the
-- rename by itself — this is why no policy is reissued here, and why the two views need only
-- their own names and output columns changed. Function bodies are the exception: they are
-- stored as text. Every function whose body names something renamed here is therefore
-- reissued in full at the bottom of this file, and the assertion block at the very end
-- refuses to finish if any body, object name or settings key still carries the old words.
--
-- Nothing about behaviour changes. If this migration alters what a single policy admits or
-- what a single trigger raises, it is wrong.

-- ── 1. The incumbent moves out of the way ────────────────────────────────────────────
-- public.reports is the moderation queue: somebody telling the moderators about a row. It
-- becomes public.flags, and the person who filed it becomes the flagger.

alter table public.reports rename to flags;
alter table public.flags rename column reporter_id to flagger_id;

alter type public.report_reason rename to flag_reason;
alter type public.report_status rename to flag_status;

-- ── 2. Enum labels ───────────────────────────────────────────────────────────────────
-- 'report' -> 'flag' before 'practice' -> 'report', for the reason in the header. A label
-- rename does not touch stored rows: the value keeps its identity and only its name moves,
-- which is also why every CHECK constraint and policy comparing against these labels needs
-- no attention here.

alter type public.moderation_target rename value 'report'      to 'flag';
alter type public.moderation_target rename value 'practice'    to 'report';
alter type public.moderation_target rename value 'proposition' to 'debate';
alter type public.moderation_target rename value 'resource'    to 'entry';

alter type public.moderation_action rename value 'resolve_report' to 'resolve_flag';
alter type public.moderation_action rename value 'dismiss_report' to 'dismiss_flag';

alter type public.content_kind rename value 'practice'    to 'report';
alter type public.content_kind rename value 'proposition' to 'debate';

-- ── 3. Tables and the columns that name their parent ─────────────────────────────────

alter table public.practices              rename to reports;
alter table public.practice_tools         rename to report_tools;
alter table public.practice_tags          rename to report_tags;
alter table public.practice_confirmations rename to report_confirmations;
alter table public.propositions           rename to debates;
alter table public.resources              rename to network_entries;

alter table public.report_tools         rename column practice_id    to report_id;
alter table public.report_tags          rename column practice_id    to report_id;
alter table public.report_confirmations rename column practice_id    to report_id;
alter table public.ratings              rename column proposition_id to debate_id;

-- ── 4. Types ─────────────────────────────────────────────────────────────────────────

alter type public.practice_area         rename to report_area;
alter type public.practice_task_type    rename to report_task_type;
alter type public.practice_outcome      rename to report_outcome;
alter type public.proposition_status    rename to debate_status;
alter type public.resource_category     rename to network_category;
alter type public.resource_link_status  rename to network_link_status;

-- ── 5. Views ─────────────────────────────────────────────────────────────────────────
-- The bodies follow the table renames on their own; the output column names do not.
-- public.debate_ratings is dropped rather than renamed because public.rating_aggregate,
-- which it calls, has a parameter to rename and CREATE OR REPLACE cannot rename one. It is
-- recreated verbatim below, security_invoker included — without which a hidden debate would
-- be visible in the aggregate to anyone who could not see the debate itself.

alter view public.practice_staleness rename to report_staleness;
alter view public.report_staleness rename column practice_id to report_id;

drop view public.proposition_ratings;

-- ── 6. Function names ────────────────────────────────────────────────────────────────
-- ALTER FUNCTION ... RENAME keeps the ACL and every trigger that fires it, so these do not
-- need re-granting; the bodies are replaced further down. The three with parameters are
-- dropped and recreated instead, because their parameter names change and the browser
-- passes arguments by name.

alter function private.assert_practice_has_tool()   rename to assert_report_has_tool;
alter function private.protect_practice_columns()   rename to protect_report_columns;
alter function private.protect_proposition_columns() rename to protect_debate_columns;
alter function private.promote_proposition()        rename to promote_debate;
alter function private.normalise_resource_url()     rename to normalise_network_url;
alter function private.protect_resource_columns()   rename to protect_network_columns;

-- Named without an argument list: each is the only function with its name, and spelling out
-- seventeen parameter types would be a second place for the signature to drift.
drop function public.submit_practice;
drop function public.resubmit_practice;
drop function public.rating_aggregate;

-- ── 7. Index, constraint, policy and trigger names ───────────────────────────────────
-- Driven off the catalogues rather than written out, because the alternative is 150 ALTERs
-- whose only failure mode is naming one that a later migration already dropped. The
-- substitutions are the same ones applied everywhere else, in the same order, and the
-- flags table goes first for the same reason the tables did.
--
-- Constraints before plain indexes: renaming a constraint renames the index behind it, and
-- renaming that index directly would leave the constraint pointing at a differently named
-- object.

do $$
declare
  v_pairs text[][] := array[
    -- The flags table only, whose objects are still named reports_*.
    array['flags',        'reports_',      'flags_'],
    array['flags',        'reporter',      'flagger'],
    -- Everything else. No trailing underscore in the pattern, because the word is not
    -- always followed by one: the trigger `ratings_promote_proposition` ends in it.
    array['%',            'practices',     'reports'],
    array['%',            'practice',      'report'],
    array['%',            'propositions',  'debates'],
    array['%',            'proposition',   'debate'],
    array['%',            'resources',     'network_entries'],
    array['%',            'resource',      'network']
  ];
  v_pair  text[];
  v_row   record;
  v_new   text;
begin
  foreach v_pair slice 1 in array v_pairs loop
    -- Constraints.
    for v_row in
      select c.conname, t.relname
        from pg_constraint c
        join pg_class     t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
       where n.nspname = 'public'
         and t.relname like v_pair[1]
         and position(v_pair[2] in c.conname) > 0
    loop
      v_new := replace(v_row.conname, v_pair[2], v_pair[3]);
      execute format('alter table public.%I rename constraint %I to %I',
                     v_row.relname, v_row.conname, v_new);
    end loop;

    -- Indexes that are not behind a constraint.
    for v_row in
      select i.relname
        from pg_class     i
        join pg_index     x on x.indexrelid = i.oid
        join pg_class     t on t.oid = x.indrelid
        join pg_namespace n on n.oid = i.relnamespace
       where n.nspname = 'public'
         and i.relkind = 'i'
         and t.relname like v_pair[1]
         and position(v_pair[2] in i.relname) > 0
         and not exists (select 1 from pg_constraint c where c.conindid = i.oid)
    loop
      execute format('alter index public.%I rename to %I',
                     v_row.relname, replace(v_row.relname, v_pair[2], v_pair[3]));
    end loop;

    -- Policies.
    for v_row in
      select p.polname, t.relname
        from pg_policy    p
        join pg_class     t on t.oid = p.polrelid
        join pg_namespace n on n.oid = t.relnamespace
       where n.nspname = 'public'
         and t.relname like v_pair[1]
         and position(v_pair[2] in p.polname) > 0
    loop
      execute format('alter policy %I on public.%I rename to %I',
                     v_row.polname, v_row.relname,
                     replace(v_row.polname, v_pair[2], v_pair[3]));
    end loop;

    -- Triggers, constraint triggers included.
    for v_row in
      select g.tgname, t.relname
        from pg_trigger   g
        join pg_class     t on t.oid = g.tgrelid
        join pg_namespace n on n.oid = t.relnamespace
       where n.nspname = 'public'
         and not g.tgisinternal
         and t.relname like v_pair[1]
         and position(v_pair[2] in g.tgname) > 0
    loop
      execute format('alter trigger %I on public.%I rename to %I',
                     v_row.tgname, v_row.relname,
                     replace(v_row.tgname, v_pair[2], v_pair[3]));
    end loop;
  end loop;
end $$;

-- ── 8. private.settings keys ─────────────────────────────────────────────────────────
-- These are read by name from inside the functions below, so a key left behind does not
-- error — it reads as "no limit configured" or "never promote", which is the quiet kind of
-- wrong. Same ordering rule: the flag limit takes the name the report limit is vacating.

update private.settings set key = 'rate_limit_flags_per_day'
 where key = 'rate_limit_reports_per_day';
update private.settings set key = 'rate_limit_reports_per_day'
 where key = 'rate_limit_practices_per_day';
update private.settings set key = 'rate_limit_entries_per_day'
 where key = 'rate_limit_resources_per_day';
update private.settings set key = 'debate_activation_ratings'
 where key = 'proposition_activation_ratings';

-- ── 9. Function bodies ───────────────────────────────────────────────────────────────
-- Reissued because a function body is text and does not follow a rename. Each is the
-- definition that was last applied, with the vocabulary substituted and nothing else
-- changed; the comment above each says which migration it came from, so the two can be read
-- side by side.

-- 20260815100300_practice_tools.sql:106
create or replace function private.assert_report_has_tool()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report_id uuid;
begin
  if tg_table_name = 'reports' then
    v_report_id := new.id;
  else
    v_report_id := old.report_id;

    -- The parent may have gone in the same statement, taking these rows with it by
    -- cascade. A report that no longer exists has no invariant left to violate.
    if not exists (
      select 1 from public.reports p where p.id = v_report_id
    ) then
      return null;
    end if;
  end if;

  if not exists (
    select 1 from public.report_tools t where t.report_id = v_report_id
  ) then
    raise exception
      'A report must record at least one tool, with its version and the date it was used.'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

-- 20260815160100_ratings.sql:86
create or replace function private.promote_debate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_threshold integer;
  v_count     integer;
begin
  select s.value::integer into v_threshold
    from private.settings s
   where s.key = 'debate_activation_ratings';

  -- An unconfigured threshold means "do not promote", never "promote everything". The
  -- debate stays proposed and a moderator can still promote it by hand.
  if v_threshold is null then
    return null;
  end if;

  select count(*) into v_count
    from public.ratings r
   where r.debate_id = new.debate_id;

  if v_count >= v_threshold then
    update public.debates p
       set status = 'active', activated_at = now()
     where p.id = new.debate_id
       and p.status = 'proposed';
  end if;

  return null;
end;
$$;

-- 20260815180000_comments.sql:150
create or replace function private.check_comment_thread()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_reply  uuid;
  v_parent_type   public.content_kind;
  v_parent_parent uuid;
begin
  if new.in_reply_to is null then
    return new;
  end if;

  select c.in_reply_to, c.parent_type, c.parent_id
    into v_parent_reply, v_parent_type, v_parent_parent
    from public.comments c
   where c.id = new.in_reply_to;

  -- Deliberately the same message whether the comment never existed or is simply not
  -- readable by this caller. Distinguishing them would turn the endpoint into a way to
  -- probe for hidden content by id.
  if not found then
    raise exception 'That comment is not available to reply to.'
      using errcode = '23503';
  end if;

  if v_parent_reply is not null then
    raise exception
      'Replies go one level deep. Reply to the comment that started this exchange instead.'
      using errcode = '23514';
  end if;

  if v_parent_type is distinct from new.parent_type
     or v_parent_parent is distinct from new.parent_id then
    raise exception 'A reply belongs to the same discussion as the comment it answers.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

-- 20260815180100_citations.sql:123
create or replace function private.check_citation_endpoints()
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

-- 20260815200300_audited_moderation_only.sql:45
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
  -- `authenticated` for a browser, and the table's owner when public.moderate() performs
  -- the update. As DEFINER this would always be the owner and the guard would never fire —
  -- which is the trap recorded in CLAUDE.md and the reason this line reads the way it does.
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

  -- Status is nobody's to set from a browser now. There is no moderator policy for this
  -- table any more, so the only callers reaching here are authors, and the queue is the
  -- only way out of pending.
  new.status := old.status;

  -- The change request belongs to the review, not to the author. It is written by
  -- public.moderate() and cleared when the report is published; an author cannot remove
  -- the note asking them to fix something. There is no column grant either — this is the
  -- second lock, for the day somebody widens the first.
  new.moderation_note    := old.moderation_note;
  new.moderation_note_at := old.moderation_note_at;
  new.moderation_note_by := old.moderation_note_by;

  -- Restoring a deleted report is a moderation action, not an authoring one. Without
  -- this, "delete" would be a toggle and a soft-deleted row could be brought back after
  -- the discussion around it had moved on.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- Past pending, the text is fixed. An account of what happened that can be rewritten
  -- after people have confirmed it still works is not a record of anything -- the
  -- confirmations would attest to a version nobody can read any more.
  if old.status <> 'pending' then
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

-- 20260815200300_audited_moderation_only.sql:135
create or replace function private.protect_debate_columns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.debates'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  new.id         := old.id;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;

  -- Promotion and hiding are decisions, and decisions are logged. public.moderate() is the
  -- only route to either.
  new.status       := old.status;
  new.activated_at := old.activated_at;

  -- The wording is fixed once anyone has rated it. People rated the sentence in front of
  -- them, and an author who could reword it afterwards would be reassigning their
  -- agreement to a claim they never saw.
  if exists (select 1 from public.ratings r where r.debate_id = old.id) then
    new.statement := old.statement;
    new.area      := old.area;
  end if;

  return new;
end;
$$;

-- 20260815200300_audited_moderation_only.sql:192
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
    if old.created_at <= now() - interval '24 hours' then
      raise exception
        'The edit window on a comment is 24 hours, and this one has passed. Post a '
        'follow-up comment instead — the thread keeps both.'
        using errcode = '23514';
    end if;

    -- And it closes early once anybody has answered. This is the same rule as a
    -- debate whose wording freezes at its first rating: people replied to the
    -- sentence in front of them, and rewriting it afterwards makes their reply answer
    -- something they never read.
    if exists (select 1 from public.comments r where r.in_reply_to = old.id) then
      raise exception
        'This comment has replies, so its text is fixed. Post a follow-up instead.'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

-- 20260816100000_resources.sql:542
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
  v_actor       uuid := (select auth.uid());
  v_role        text;
  v_banned      boolean;
  v_reason      text := nullif(btrim(coalesce(p_reason, '')), '');
  v_author      uuid;
  v_status      text;
  v_target_role text;
  v_user        uuid;
  v_audit       uuid;
begin
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

  if p_action in ('hide', 'request_changes', 'ban') and v_reason is null then
    raise exception
      'Hiding something, sending it back, and banning an account each need a reason. One sentence is enough, and it is kept.'
      using errcode = '23514';
  end if;

  -- ── Reports ─────────────────────────────────────────────────────────────────────

  if p_target_type = 'report' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.reports x
     where x.id = p_target_id
       and x.deleted_at is null;

    if not found then
      raise exception 'That report is no longer in the queue. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own submission, and it goes through the same review as anyone else''s. Another moderator has to decide it.'
        using errcode = '42501';
    end if;

    if p_action = 'publish' then
      if v_status <> 'pending' then
        raise exception 'Only a submission still waiting for review can be published.'
          using errcode = '23514';
      end if;

      update public.reports
         set status             = 'published',
             moderation_note    = null,
             moderation_note_at = null,
             moderation_note_by = null
       where id = p_target_id;

    elsif p_action = 'request_changes' then
      if v_status <> 'pending' then
        raise exception
          'Changes can only be asked for while a submission is still waiting for review.'
          using errcode = '23514';
      end if;

      update public.reports
         set moderation_note    = v_reason,
             moderation_note_at = now(),
             moderation_note_by = v_actor
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That report is already hidden.'
          using errcode = '23514';
      end if;

      update public.reports set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That report is not hidden.'
          using errcode = '23514';
      end if;

      update public.reports set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a report.'
        using errcode = '23514';
    end if;

  -- ── Debates ──────────────────────────────────────────────────────────────────

  elsif p_target_type = 'debate' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.debates x
     where x.id = p_target_id;

    if not found then
      raise exception 'That debate is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own debate. Promoting it yourself is the shortcut this queue exists to prevent.'
        using errcode = '42501';
    end if;

    if p_action = 'promote' then
      if v_status <> 'proposed' then
        raise exception 'Only a proposed claim can be promoted.'
          using errcode = '23514';
      end if;

      update public.debates
         set status = 'active', activated_at = now()
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That debate is already hidden.'
          using errcode = '23514';
      end if;

      update public.debates
         set status = 'hidden', activated_at = null
       where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That debate is not hidden.'
          using errcode = '23514';
      end if;

      update public.debates
         set status = 'proposed', activated_at = null
       where id = p_target_id;

    else
      raise exception 'That action does not apply to a debate.'
        using errcode = '23514';
    end if;

  -- ── Comments ──────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'comment' then
    select x.author_id, x.status::text
      into v_author, v_status
      from public.comments x
     where x.id = p_target_id;

    if not found then
      raise exception 'That comment is no longer there. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own comment. Delete it as its author instead — that is a different act and it is recorded as one.'
        using errcode = '42501';
    end if;

    if p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That comment is already hidden.'
          using errcode = '23514';
      end if;

      update public.comments set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That comment is not hidden.'
          using errcode = '23514';
      end if;

      update public.comments set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to a comment.'
        using errcode = '23514';
    end if;

  -- ── Flags ───────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'flag' then
    select r.status::text
      into v_status
      from public.flags r
     where r.id = p_target_id;

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

    update public.flags
       set status = case when p_action = 'resolve_flag'
                         then 'actioned'::public.flag_status
                         else 'dismissed'::public.flag_status
                    end,
           resolved_at = now(),
           resolved_by = v_actor
     where id = p_target_id;

  -- ── Network ─────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'entry' then
    select x.submitter_id, x.status::text
      into v_author, v_status
      from public.network_entries x
     where x.id = p_target_id
       and x.deleted_at is null;

    if not found then
      raise exception 'That entry is no longer in the queue. Reload the page.'
        using errcode = '23503';
    end if;

    if v_author is not distinct from v_actor then
      raise exception
        'This is your own submission, and it goes through the same review as anyone else''s. Another moderator has to decide it.'
        using errcode = '42501';
    end if;

    if p_action = 'publish' then
      if v_status <> 'pending' then
        raise exception 'Only a submission still waiting for review can be published.'
          using errcode = '23514';
      end if;

      update public.network_entries
         set status             = 'published',
             moderation_note    = null,
             moderation_note_at = null,
             moderation_note_by = null
       where id = p_target_id;

    elsif p_action = 'request_changes' then
      if v_status <> 'pending' then
        raise exception
          'Changes can only be asked for while a submission is still waiting for review.'
          using errcode = '23514';
      end if;

      update public.network_entries
         set moderation_note    = v_reason,
             moderation_note_at = now(),
             moderation_note_by = v_actor
       where id = p_target_id;

    elsif p_action = 'hide' then
      if v_status = 'hidden' then
        raise exception 'That entry is already hidden.'
          using errcode = '23514';
      end if;

      update public.network_entries set status = 'hidden' where id = p_target_id;

    elsif p_action = 'unhide' then
      if v_status <> 'hidden' then
        raise exception 'That entry is not hidden.'
          using errcode = '23514';
      end if;

      update public.network_entries set status = 'published' where id = p_target_id;

    else
      raise exception 'That action does not apply to an entry.'
        using errcode = '23514';
    end if;

  -- ── Accounts ──────────────────────────────────────────────────────────────────────

  elsif p_target_type = 'account' then

    if p_action in ('ban', 'unban') then
      if p_target_id = v_actor then
        raise exception 'An account cannot ban itself.'
          using errcode = '42501';
      end if;

      select p.role
        into v_target_role
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

      update public.profiles
         set is_banned = (p_action = 'ban')
       where id = p_target_id;

    elsif p_action = 'erase_account' then
      if v_role <> 'admin' then
        raise exception 'Erasing an account is an admin action.'
          using errcode = '42501';
      end if;

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

      delete from auth.users u where u.id = v_user;

    else
      raise exception 'That action does not apply to an account.'
        using errcode = '23514';
    end if;

  else
    raise exception 'public.moderate() has no rule for target %', p_target_type
      using errcode = '0A000';
  end if;

  -- ── The record ────────────────────────────────────────────────────────────────────

  insert into public.moderation_actions (actor_id, action, target_type, target_id, reason)
  values (
    v_actor,
    p_action,
    p_target_type,
    case when p_action = 'erase_account' then null else p_target_id end,
    v_reason
  )
  returning id into v_audit;

  return v_audit;
end;
$$;

-- 20260817120000_fix_resource_trigger_bugs.sql:30
create or replace function private.enforce_daily_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author  uuid;
  v_limit   integer;
  v_count   integer;
  v_key     text;
  v_noun    text;
begin
  case tg_table_name
    when 'reports' then
      v_key    := 'rate_limit_reports_per_day';
      v_noun   := 'reports';
      v_author := new.author_id;

      select count(*) into v_count
        from public.reports p
       where p.author_id = v_author
         and p.created_at > now() - interval '24 hours';

    when 'report_confirmations' then
      v_key    := 'rate_limit_confirmations_per_day';
      v_noun   := 'confirmations';
      v_author := new.user_id;

      select count(*) into v_count
        from public.report_confirmations c
       where c.user_id = v_author
         and c.created_at > now() - interval '24 hours';

    when 'comments' then
      v_key    := 'rate_limit_comments_per_day';
      v_noun   := 'comments';
      v_author := new.author_id;

      select count(*) into v_count
        from public.comments c
       where c.author_id = v_author
         and c.created_at > now() - interval '24 hours';

    when 'citations' then
      v_key    := 'rate_limit_citations_per_day';
      v_noun   := 'citations';
      v_author := new.created_by;

      select count(*) into v_count
        from public.citations c
       where c.created_by = v_author
         and c.created_at > now() - interval '24 hours';

    when 'flags' then
      v_key    := 'rate_limit_flags_per_day';
      v_noun   := 'flags';
      v_author := new.flagger_id;

      select count(*) into v_count
        from public.flags r
       where r.flagger_id = v_author
         and r.created_at > now() - interval '24 hours';

    when 'network_entries' then
      v_key    := 'rate_limit_entries_per_day';
      v_noun   := 'entries';
      v_author := new.submitter_id;

      select count(*) into v_count
        from public.network_entries r
       where r.submitter_id = v_author
         and r.created_at > now() - interval '24 hours';

    else
      raise exception 'private.enforce_daily_limit() has no rule for table %', tg_table_name
        using errcode = '0A000';
  end case;

  if v_author is null then
    return new;
  end if;

  select s.value::integer into v_limit
    from private.settings s
   where s.key = v_key;

  if v_limit is null then
    raise exception 'Rate limit % is not configured.', v_key
      using errcode = '53400';
  end if;

  if v_count >= v_limit then
    raise exception
      'Daily limit reached: % % in the last 24 hours, which is the maximum. Try again later.',
      v_count, v_noun
      using errcode = '53400',
            hint = 'This limit exists so one account cannot bury a volunteer moderation queue.';
  end if;

  return new;
end;
$$;

-- 20260817120000_fix_resource_trigger_bugs.sql:148
create or replace function private.normalise_network_url()
returns trigger
language plpgsql
security definer        -- must reach private.normalise_url; INSERT also needs this
set search_path = ''
as $$
begin
  new.url_normalised := private.normalise_url(new.url);
  return new;
end;
$$;

-- 20260817120000_fix_resource_trigger_bugs.sql:175
create or replace function private.protect_network_columns()
returns trigger
language plpgsql
security invoker        -- must remain INVOKER: current_user check decides who is trusted
set search_path = ''
as $$
declare
  v_is_trusted boolean;
begin
  -- url_normalised was already set by normalise_network_url() which fires before this
  -- trigger (alphabetical: network_entries_a_ before network_entries_b_). The old direct call to
  -- private.normalise_url() is removed because the authenticated role cannot reach the
  -- private schema, causing every browser UPDATE to fail with permission denied.
  new.updated_at := now();

  v_is_trusted :=
       current_user = 'service_role'
    or pg_has_role(
         current_user,
         (select c.relowner
            from pg_catalog.pg_class c
           where c.oid = 'public.network_entries'::pg_catalog.regclass),
         'USAGE');

  if v_is_trusted then
    return new;
  end if;

  -- Immutable for everyone.
  new.id           := old.id;
  new.submitter_id := old.submitter_id;
  new.created_at   := old.created_at;

  -- Status, link check, and moderation columns are for moderators and the link-check
  -- script respectively. No browser caller may write them.
  new.status             := old.status;
  new.link_status        := old.link_status;
  new.link_checked_at    := old.link_checked_at;
  new.moderation_note    := old.moderation_note;
  new.moderation_note_at := old.moderation_note_at;
  new.moderation_note_by := old.moderation_note_by;

  -- Restoring a deleted entry is a moderation action.
  if old.deleted_at is not null then
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
  end if;

  -- Once past pending, the content is fixed.
  if old.status <> 'pending' then
    new.title          := old.title;
    new.url            := old.url;
    new.url_normalised := old.url_normalised;
    new.category       := old.category;
    new.description    := old.description;
    new.relevance      := old.relevance;
  end if;

  return new;
end;
$$;

-- 20260815140000_submit_practice.sql:28
create or replace function public.submit_report(
  p_title                          text,
  p_area                           public.report_area,
  p_task_type                      public.report_task_type,
  -- [{"name": "GPT-5", "version": "2026-05", "used_on": "2026-08-01"}, ...]
  p_tools                          jsonb,
  p_aim                            text,
  p_method                         text,
  p_outcome                        public.report_outcome,
  p_outcome_notes                  text,
  p_verification                   text,
  p_third_party_material_confirmed boolean,
  p_transcript_excerpt             text     default null,
  p_transcript_url                 text     default null,
  p_caveats                        text     default null,
  p_time_spent_minutes             integer  default null,
  p_was_published                  boolean  default null,
  p_was_disclosed                  boolean  default null,
  -- integer, although the column is smallint. Postgres will not implicitly narrow an
  -- integer literal to smallint while resolving which function to call, so a smallint
  -- parameter makes `submit_report(..., 8, ...)` fail with "function does not exist" --
  -- a message that sends you looking for a missing migration rather than a missing cast.
  -- The assignment cast to the column happens on INSERT, where it is unambiguous, and the
  -- range is checked there by reports_author_confidence_range.
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}'
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id   uuid;
  v_tool jsonb;
begin
  -- Checked here as well as by the deferred trigger, purely so the message is a sentence
  -- about the form rather than one about a constraint. The trigger is still the truth; a
  -- caller that skipped this function would meet it instead.
  if p_tools is null
     or jsonb_typeof(p_tools) <> 'array'
     or jsonb_array_length(p_tools) = 0 then
    raise exception 'Record at least one tool, with its version and the date you used it.'
      using errcode = '23514';
  end if;

  if jsonb_array_length(p_tools) > 20 then
    raise exception 'That is more tools than one account of a session can usefully describe.'
      using errcode = '23514';
  end if;

  insert into public.reports (
    author_id, title, area, task_type, aim, method, outcome, outcome_notes, verification,
    transcript_excerpt, transcript_url, caveats, third_party_material_confirmed,
    time_spent_minutes, was_published, was_disclosed, author_confidence
  )
  values (
    -- Not a parameter, and never will be.
    (select auth.uid()),
    p_title, p_area, p_task_type, p_aim, p_method, p_outcome, p_outcome_notes,
    p_verification, p_transcript_excerpt, p_transcript_url, p_caveats,
    p_third_party_material_confirmed, p_time_spent_minutes, p_was_published,
    p_was_disclosed, p_author_confidence
  )
  returning id into v_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.report_tools (report_id, tool_name, tool_version, used_on)
    values (
      v_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date
    );
  end loop;

  -- Tags are matched by code rather than by id, so the client never has to know the uuids,
  -- and an unknown or retired code is silently dropped instead of failing a submission
  -- somebody spent ten minutes on. Retiring a tag between page load and submit is rare and
  -- losing a tag is a far smaller harm than losing the account of the work.
  insert into public.report_tags (report_id, tag_id)
  select v_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;

  return v_id;
end;
$$;

-- 20260817110000_resubmit_practice.sql:30
create or replace function public.resubmit_report(
  p_report_id                      uuid,
  p_title                          text,
  p_area                           public.report_area,
  p_task_type                      public.report_task_type,
  -- [{"name": "GPT-5", "version": "2026-05", "used_on": "2026-08-01"}, ...]
  p_tools                          jsonb,
  p_aim                            text,
  p_method                         text,
  p_outcome                        public.report_outcome,
  p_outcome_notes                  text,
  p_verification                   text,
  p_third_party_material_confirmed boolean,
  p_transcript_excerpt             text     default null,
  p_transcript_url                 text     default null,
  p_caveats                        text     default null,
  p_time_spent_minutes             integer  default null,
  p_was_published                  boolean  default null,
  p_was_disclosed                  boolean  default null,
  -- integer rather than smallint, for the same reason as in submit_report: Postgres
  -- cannot implicitly narrow an integer literal to smallint during overload resolution,
  -- producing a "function does not exist" error that looks like a missing migration.
  p_author_confidence              integer  default null,
  p_tag_codes                      text[]   default '{}'
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_updated integer;
  v_tool    jsonb;
begin
  -- Validate tool count before touching anything, so the error message names the form
  -- field rather than a constraint. The deferred trigger is still the true enforcer.
  if p_tools is null
     or jsonb_typeof(p_tools) <> 'array'
     or jsonb_array_length(p_tools) = 0 then
    raise exception 'Record at least one tool, with its version and the date you used it.'
      using errcode = '23514';
  end if;

  if jsonb_array_length(p_tools) > 20 then
    raise exception 'That is more tools than one account of a session can usefully describe.'
      using errcode = '23514';
  end if;

  -- The update will match zero rows if the report does not exist, is not pending, or is
  -- not owned by the caller (reports_update_own_pending refuses it). Check the count so
  -- the caller gets a clear error rather than silent success followed by a puzzling state.
  update public.reports set
    title                          = btrim(p_title),
    area                           = p_area,
    task_type                      = p_task_type,
    aim                            = btrim(p_aim),
    method                         = btrim(p_method),
    outcome                        = p_outcome,
    outcome_notes                  = btrim(p_outcome_notes),
    verification                   = btrim(p_verification),
    third_party_material_confirmed = p_third_party_material_confirmed,
    transcript_excerpt             = nullif(btrim(coalesce(p_transcript_excerpt, '')), ''),
    transcript_url                 = nullif(btrim(coalesce(p_transcript_url, '')), ''),
    caveats                        = nullif(btrim(coalesce(p_caveats, '')), ''),
    time_spent_minutes             = p_time_spent_minutes,
    was_published                  = p_was_published,
    was_disclosed                  = p_was_disclosed,
    author_confidence              = p_author_confidence
  where id = p_report_id;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception 'This submission was not found, or it is no longer pending.'
      using errcode = 'P0002';
  end if;

  -- Replace tools atomically. The deferred constraint sees the final state — the new rows
  -- inserted below — rather than the empty intermediate. See the header.
  delete from public.report_tools where report_id = p_report_id;

  for v_tool in select * from jsonb_array_elements(p_tools)
  loop
    insert into public.report_tools (report_id, tool_name, tool_version, used_on)
    values (
      p_report_id,
      v_tool ->> 'name',
      v_tool ->> 'version',
      (v_tool ->> 'used_on')::date
    );
  end loop;

  -- Replace tags. Unknown or retired codes are silently dropped, as in submit_report.
  delete from public.report_tags where report_id = p_report_id;

  insert into public.report_tags (report_id, tag_id)
  select p_report_id, t.id
    from public.tags t
   where t.code = any (p_tag_codes)
     and t.is_active;
end;
$$;

-- 20260815160200_rating_aggregate.sql:35
create or replace function public.rating_aggregate(p_debate uuid)
returns table (
  -- Eleven counts, index 1 holding the count of score 0 through index 11 holding score 10.
  -- An array rather than eleven columns because every consumer wants it as a sequence:
  -- the histogram component iterates it, and the export carries it as a JSON array.
  histogram integer[],
  median smallint,
  -- Everyone who answered, including those who declined. The denominator of coverage.
  total_raters integer,
  -- Those who put a number on it.
  opinion_count integer,
  -- Those who said "no opinion / outside my expertise". A real answer, off the scale.
  no_opinion_count integer,
  -- opinion_count / total_raters, to three places. Flagged as its own number because a
  -- median over four opinions out of forty raters means something very different from a
  -- median over thirty-eight.
  coverage numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    -- Written out rather than generated. A `select ... from generate_series(0, 10)`
    -- subquery here references r.score from the enclosing aggregate query, where it is
    -- ungrouped, and Postgres rejects it: "subquery uses ungrouped column from outer
    -- query". Eleven lines that are obviously correct beat a clever one that is not.
    array[
      count(*) filter (where r.score = 0)::integer,
      count(*) filter (where r.score = 1)::integer,
      count(*) filter (where r.score = 2)::integer,
      count(*) filter (where r.score = 3)::integer,
      count(*) filter (where r.score = 4)::integer,
      count(*) filter (where r.score = 5)::integer,
      count(*) filter (where r.score = 6)::integer,
      count(*) filter (where r.score = 7)::integer,
      count(*) filter (where r.score = 8)::integer,
      count(*) filter (where r.score = 9)::integer,
      count(*) filter (where r.score = 10)::integer
    ],
    -- FILTER rather than relying on how the ordered-set aggregate treats nulls. Being
    -- explicit costs nothing and the alternative is a median that silently includes the
    -- people who declined to give one.
    (percentile_disc(0.5) within group (order by r.score)
       filter (where r.score is not null))::smallint,
    count(*)::integer,
    count(r.score)::integer,
    count(*) filter (where r.score is null)::integer,
    round(count(r.score)::numeric / nullif(count(*), 0), 3)
  from public.ratings r
  where r.debate_id = p_debate
    -- A moderated-away debate flags nothing, even to a caller who names its id.
    and exists (
      select 1
        from public.debates q
       where q.id = p_debate
         and q.status <> 'hidden'
    );
$$;

-- ── 10. Grants for the three functions that were dropped ─────────────────────────────
-- CREATE OR REPLACE keeps an ACL; DROP takes it with the function. Postgres also grants
-- EXECUTE to PUBLIC on every new function, so the revoke is not optional — migrate.yml
-- asserts in production that no private function is reachable by a browser role.

revoke all on function public.submit_report from public;
grant execute on function public.submit_report to authenticated;

revoke all on function public.resubmit_report from public;
grant execute on function public.resubmit_report to authenticated;

revoke all on function public.rating_aggregate(uuid) from public;
grant execute on function public.rating_aggregate(uuid) to anon, authenticated;

-- ── 11. public.debate_ratings, rebuilt on the new aggregate ──────────────────────────
-- security_invoker is the whole defence here: a view has no row level security of its own,
-- so without it this would hand a hidden debate's histogram to anyone who asked.

create view public.debate_ratings
with (security_invoker = on) as
select
  p.id as debate_id,
  a.histogram,
  a.median,
  a.total_raters,
  a.opinion_count,
  a.no_opinion_count,
  a.coverage
from public.debates p
-- LATERAL, and a cross join rather than a left one: the function is an aggregate query
-- without GROUP BY, so it returns exactly one row for every debate including those nobody
-- has rated. Those come back as an all-zero histogram with a null median, which is the
-- correct description of a debate nobody has answered.
cross join lateral public.rating_aggregate(p.id) a;

grant select on public.debate_ratings to anon, authenticated;

-- ── 12. Object comments ──────────────────────────────────────────────────────────────
-- Every comment whose text moved under the rename, reissued. These are read in the Supabase
-- table editor and by anyone doing \d+ on a dump, which makes them the last place the old
-- vocabulary would have survived unnoticed.

comment on type public.report_area is
  'What kind of mathematical work the report describes.';

comment on type public.report_task_type is
  'What the tool was asked to do. The primary axis for grouping the corpus.';

comment on type public.report_outcome is
  'What the author flags happened. Matches OUTCOMES in src/lib/status.ts. A failure is a '
  'first-class contribution, not a lesser one.';

comment on type public.confirmation_verdict is
  'A reader''s flag on whether a report still reproduces. Drives the tombstone.';

comment on table public.reports is
  'First-hand accounts of AI tool use in mathematical work. The corpus. Soft-delete only; '
  'there is no DELETE grant or policy anywhere.';

comment on column public.reports.author_id is
  'Nullable by design. ON DELETE SET NULL is the account erasure path: the account goes, '
  'the contribution stays in the corpus under CC BY without attribution.';

comment on column public.reports.verification is
  'How the author checked the result was correct. Required, with no skip and no "not '
  'applicable". The field that makes this corpus mathematically serious.';

comment on column public.reports.third_party_material_confirmed is
  'The author''s affirmation that third-party unpublished material was removed from the '
  'transcript. Constrained true: the row cannot exist without it.';

comment on column public.reports.transcript_excerpt is
  'The canonical artifact. A share link is supplementary because links expire, are revoked, '
  'and may breach provider terms.';

comment on function private.protect_report_columns() is
  'Reverts writes to columns the caller does not own. SECURITY INVOKER: as DEFINER, '
  'current_user would always be the owner and the guard would never fire. Since the '
  'moderator UPDATE policy was dropped, everyone reaching here is an author.';

comment on table public.report_tools is
  'Tools used in a report, with version and date. At least one row per report, '
  'enforced by a deferred constraint trigger.';

comment on column public.report_tools.used_on is
  'When the tool was used. Mandatory: the staleness signal on every listing is derived '
  'from the most recent of these.';

comment on function private.assert_report_has_tool() is
  'Deferred check that a report has at least one tool row. SECURITY DEFINER so the count '
  'is the true one rather than whatever the caller''s policies leave visible.';

comment on column public.tags.is_active is
  'False retires a tag from the form without breaking reports that already carry it.';

comment on table public.report_tags is
  'Which tags a report carries. RESTRICT on tag_id: retiring a tag is is_active = false, '
  'never a delete that would silently untag existing work.';

comment on table public.report_confirmations is
  'Reader flags on whether a report still reproduces. One per person per report, '
  'editable, no history kept.';

comment on column public.report_confirmations.user_id is
  'CASCADE on account erasure: a confirmation is one person''s flag rather than a durable '
  'contribution, so it goes with them.';

comment on view public.report_staleness is
  'Per report: most recent tool use, latest confirmation, and the derived tombstone. '
  'SECURITY INVOKER -- without it this view would return pending and hidden reports to '
  'anonymous callers.';

comment on function private.enforce_daily_limit() is
  'Refuses an insert that would exceed the per-author rolling 24 hour limit in '
  'private.settings. SECURITY DEFINER so the count includes rows the caller cannot see and '
  'so the threshold itself stays unreadable from a browser. Covers reports, confirmations, '
  'comments, citations, flags, and entries.';

comment on function public.submit_report is
  'Creates a report with its tools and tags in one transaction, which the deferred '
  'at-least-one-tool constraint makes necessary. SECURITY INVOKER: every policy on the '
  'underlying tables still applies, and the author is auth.uid() rather than a parameter.';

comment on constraint reports_link_needs_excerpt on public.reports is
  'A share link is supplementary and never the only record. Links expire, are revoked, and '
  'may breach provider terms; the excerpt is ours and is what the export carries.';

comment on type public.debate_status is
  'Lifecycle of a debate. Distinct from content_status: a debate is rateable while '
  'proposed, which has no equivalent for a report.';

comment on table public.debates is
  'A single claim that can be agreed with. The only thing ratings attach to.';

comment on column public.debates.statement is
  'One claim, 200 characters. Two claims sharing a rating produce an aggregate nobody can '
  'interpret.';

comment on column public.debates.activated_at is
  'When it became part of the record, by moderator promotion or by reaching the rating '
  'threshold in private.settings.';

comment on function private.protect_debate_columns() is
  'Reverts writes the caller does not own. SECURITY INVOKER: as DEFINER, current_user would '
  'always be the owner and the guard would never fire. Status and activation are '
  'public.moderate()''s alone.';

comment on table public.ratings is
  'One answer per person per debate. Editable, no history: the aggregate flags what '
  'people currently think.';

comment on function private.promote_debate() is
  'Promotes a proposed debate once it reaches the rating count in private.settings. '
  'Counts NULL scores too: promotion records that the question was worth asking.';

comment on function public.rating_aggregate(uuid) is
  'Histogram, median and counts for one debate. SECURITY DEFINER so it can count rows '
  'the caller cannot read: individual ratings are visible only to their author. Returns no '
  'mean, and no value attributable to a person.';

comment on view public.debate_ratings is
  'Per debate: the histogram, median and counts. SECURITY INVOKER, so a hidden '
  'debate is absent for anyone who cannot see the debate itself.';

comment on type public.content_kind is
  'What a row points at. Restricted per table by CHECK: comments and citations accept only '
  'report and debate, flags accept all three.';

comment on table public.comments is
  'Discussion on a report or a debate. One level of nesting. Published on insert and '
  'moderated reactively; soft-delete empties the body and strips the author but keeps the '
  'node so replies still read.';

comment on table public.citations is
  'A report or debate referencing another, optionally with the exact comment at '
  'either end. Immutable: no UPDATE grant. The excerpt is stored so a quotation survives '
  'its target being edited or hidden.';

comment on table public.flags is
  'Flags of content, readable by their author and by moderators and nobody else. Never '
  'displayed next to the flagged row: a visible flag count is a downvote.';

comment on column public.reports.moderation_note is
  'The current change request from a moderator, written for the author and shown to them on '
  'their account page. One at a time; the history is in public.moderation_actions.';

comment on column public.reports.moderation_note_at is
  'When the change was asked for. Shown to the author so an old request is visibly old.';

comment on column public.reports.moderation_note_by is
  'Which moderator asked. Never shown to the author — the note is the answer, not the '
  'person. Kept so the queue can show who has already looked at something.';

comment on function public.moderate(public.moderation_target, uuid, public.moderation_action, text) is
  'The only audited route for a moderation decision. SECURITY DEFINER so it can write rows '
  'the caller cannot, and it authorises on auth.uid() rather than current_user. Covers '
  'reports, debates, comments, flags, entries, and accounts.';

comment on function private.normalise_url(text) is
  'Canonical form of a URL for deduplication: lowercased, scheme stripped, trailing '
  'slash stripped, tracking parameters removed. Kept in sync with the client-side '
  'normaliseUrl() in src/pages/network/new.astro.';

comment on type public.network_category is
  'Purpose of a linked entry. ''formalisation'' specifically covers proof assistants and '
  'libraries; ''reading'' is for papers and flags rather than tools.';

comment on type public.network_link_status is
  'Result of the most recent automated link check. Null until the first check runs. '
  '''redirected'' means a 3xx was returned; the URL still resolves but may have moved. '
  '''unreachable'' covers 4xx that are not bot-rejections, 5xx, and timeouts.';

comment on table public.network_entries is
  'Community-curated links, each moderated before publication and checked monthly for '
  'liveness. Duplicate URLs are rejected by the partial unique index on url_normalised.';

comment on column public.network_entries.url_normalised is
  'Lowercased, scheme-stripped, tracking-parameter-free form of url. Set by trigger; '
  'never written by a caller. The unique index uses this column so UTM variants of the '
  'same link count as one submission.';

comment on column public.network_entries.link_status is
  'Null until the first monthly link check. Unreachable entries are sorted last on the '
  'listing page and visibly marked; they are never silently hidden.';

comment on column public.network_entries.moderation_note is
  'Readable by the submitter under "Your submissions". Never shown to the general public; '
  'never shown to other moderators via the queue (they see moderation_note_at to know a '
  'request was made, not what it said).';

comment on function private.normalise_network_url() is
  'Sets url_normalised from url before every insert or update. SECURITY DEFINER: '
  'private.normalise_url is in the private schema and the authenticated role cannot '
  'call it directly. Alphabetical trigger order puts this before protect_network_columns, '
  'so the guard always sees an already-normalised value.';

comment on function private.protect_network_columns() is
  'Reverts writes to columns the caller does not own. Deliberately SECURITY INVOKER: '
  'as DEFINER, current_user would always be the owner and the guard would never fire. '
  'URL normalisation is handled by the preceding normalise_network_url() trigger.';

comment on function public.resubmit_report is
  'Replaces a pending report''s content, tools, and tags in one transaction — the deferred '
  'at-least-one-tool constraint makes the function necessary, for the same reason as '
  'submit_report. SECURITY INVOKER: the caller''s policies are the only guards needed.';

-- ── 13. private.settings notes ───────────────────────────────────────────────────────
-- Prose, not identifiers, and read by whoever next wonders why a limit is what it is.

update private.settings
   set note = 'Reports one author may submit per rolling 24 hours. Ten is far past any '
              'honest session -- a well-structured account takes the better part of an '
              'hour -- and well short of what would bury the moderation queue.'
 where key = 'rate_limit_reports_per_day';

update private.settings
   set note = 'Still-works confirmations one account may file per rolling 24 hours. Higher '
              'than the report limit because working through a listing and saying what '
              'still works in an afternoon is exactly the behaviour we want, and cheap to '
              'review.'
 where key = 'rate_limit_confirmations_per_day';

update private.settings
   set note = 'Flags per account per rolling 24 hours. Deliberately the lowest limit on the '
              'site. Twenty is far past anyone reading in good faith, and a flag queue is '
              'the one thing here that a single determined account could make unusable for '
              'volunteers.'
 where key = 'rate_limit_flags_per_day';

update private.settings
   set note = 'Network entries one submitter may submit per rolling 24 hours. Tighter than '
              'reports (10) because a link submission costs the submitter nothing and is '
              'the most likely spam vector on the site.'
 where key = 'rate_limit_entries_per_day';

update private.settings
   set note = 'How many ratings promote a proposed debate to active without a moderator. '
              'Low on purpose: the point of promotion is that enough people cared to '
              'answer, not that a quorum agreed. A moderator can promote or hide one at '
              'any time regardless.'
 where key = 'debate_activation_ratings';

-- ── 14. The rename is complete, or this migration does not finish ────────────────────
-- A rename that is 95% done is worse than one not started: the missing 5% is a function
-- body that still names public.practices and fails the first time somebody submits, months
-- later, with nothing in the diff to suggest why. So the migration checks its own work and
-- refuses to commit if any of it survived.
--
-- "resource" is allowed in prose about HTTP responses, so only identifiers are checked for
-- it, never comment text.

do $$
declare
  v_leftovers text;
begin
  -- Relations, types and functions.
  select string_agg(what, ', ' order by what) into v_leftovers from (
    select n.nspname || '.' || c.relname as what
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and c.relkind in ('r', 'v', 'm', 'i')
       and c.relname ~ '(practice|proposition|resource|reporter)'
    union all
    select n.nspname || '.' || t.typname
      from pg_type t
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname in ('public', 'private')
       and t.typname ~ '(practice|proposition|resource|reporter)'
    union all
    select n.nspname || '.' || p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and p.proname ~ '(practice|proposition|resource|reporter)'
    union all
    select 'constraint ' || c.conname
      from pg_constraint c
      join pg_namespace n on n.oid = c.connamespace
     where n.nspname in ('public', 'private')
       and c.conname ~ '(practice|proposition|resource|reporter)'
    union all
    select 'policy ' || p.polname
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and p.polname ~ '(practice|proposition|resource|reporter)'
    union all
    select 'trigger ' || g.tgname
      from pg_trigger g
      join pg_class c on c.oid = g.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and not g.tgisinternal
       and g.tgname ~ '(practice|proposition|resource|reporter)'
    union all
    -- Tables and views only. An index has pg_attribute rows of its own, and Postgres does
    -- not rewrite their attnames when the underlying table column is renamed, so
    -- report_tools_report_idx keeps a key column called practice_id for ever. Nothing reads
    -- it: \d prints an index through pg_get_indexdef, which resolves against the table. It
    -- is an artefact, not a leftover, and including indexes here made this assertion fail on
    -- a rename that was complete.
    select 'column ' || c.relname || '.' || a.attname
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'private')
       and c.relkind in ('r', 'v', 'm', 'p')
       and a.attnum > 0
       and not a.attisdropped
       and a.attname ~ '(practice|proposition|resource|reporter)'
    union all
    select 'enum label ' || t.typname || '.' || e.enumlabel
      from pg_enum e
      join pg_type t on t.oid = e.enumtypid
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname in ('public', 'private')
       and e.enumlabel ~ '(practice|proposition|resource|reporter)'
    union all
    select 'setting ' || s.key
      from private.settings s
     where s.key ~ '(practice|proposition|resource|reporter)'
    union all
    -- Function bodies, which do not follow a rename because they are text.
    select 'body of ' || n.nspname || '.' || p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and p.prosrc ~ '(practice|proposition|public\.resources|resource_)'
  ) leftovers;

  if v_leftovers is not null then
    raise exception 'Rename incomplete, the old vocabulary survives in: %', v_leftovers
      using errcode = '0A000';
  end if;
end $$;
