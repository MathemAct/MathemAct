-- Rate limits for the three tables prompt 10 adds.
--
-- private.enforce_daily_limit() was written with a `case tg_table_name` and an `else` that
-- raises, precisely so that attaching it to a new table without teaching it about that
-- table is a loud failure rather than a silent absence of limiting. This is that lesson
-- being paid for: three new branches, then three new triggers.
--
-- Migrations are append-only, so the function is replaced rather than edited. CREATE OR
-- REPLACE leaves existing privileges alone, but the REVOKE is repeated below anyway —
-- an explicit revoke costs nothing and the alternative is depending on a fact about
-- CREATE OR REPLACE that nobody reading this file can see.

insert into private.settings (key, value, note) values
  ('rate_limit_citations_per_day', '100',
   'Citations one account may create per rolling 24 hours. High, because reading through '
   'the corpus and linking what belongs together is exactly the work this site wants and '
   'each one is a link rather than a piece of prose. Low enough that a runaway script '
   'stops before the moderation queue notices.'),

  ('rate_limit_reports_per_day', '20',
   'Reports per account per rolling 24 hours. Deliberately the lowest limit on the site. '
   'Twenty is far past anyone reading in good faith, and a report queue is the one thing '
   'here that a single determined account could make unusable for volunteers.');

-- The comment limit was seeded with the practice limits in 20260815100700, before the
-- table existed, so there is nothing to insert for it here.

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
    when 'practices' then
      v_key    := 'rate_limit_practices_per_day';
      v_noun   := 'practices';
      v_author := new.author_id;

      select count(*) into v_count
        from public.practices p
       where p.author_id = v_author
         and p.created_at > now() - interval '24 hours';

    when 'practice_confirmations' then
      v_key    := 'rate_limit_confirmations_per_day';
      v_noun   := 'confirmations';
      v_author := new.user_id;

      select count(*) into v_count
        from public.practice_confirmations c
       where c.user_id = v_author
         and c.created_at > now() - interval '24 hours';

    when 'comments' then
      v_key    := 'rate_limit_comments_per_day';
      v_noun   := 'comments';
      v_author := new.author_id;

      -- Deleted comments are counted. Deleting is not a way to buy another slot, and a
      -- soft-deleted row cost the moderation queue the same attention as a live one.
      -- SECURITY DEFINER is what makes this true: as INVOKER the count would run under the
      -- author's own row level security and a comment somebody had hidden would not be
      -- counted, so the fastest way past the limit would be to get moderated.
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

    when 'reports' then
      v_key    := 'rate_limit_reports_per_day';
      v_noun   := 'reports';
      v_author := new.reporter_id;

      select count(*) into v_count
        from public.reports r
       where r.reporter_id = v_author
         and r.created_at > now() - interval '24 hours';

    else
      -- A trigger was attached to a table this function does not know about. Refusing is
      -- the only safe answer: silently allowing would mean a table believed to be limited
      -- was not, and nothing would ever say so.
      raise exception 'private.enforce_daily_limit() has no rule for table %', tg_table_name
        using errcode = '0A000';
  end case;

  -- An author of null is an insert with no owner, which the policies already refuse. There
  -- is nothing to count and nothing to attribute, so this does not decide the outcome.
  if v_author is null then
    return new;
  end if;

  select s.value::integer into v_limit
    from private.settings s
   where s.key = v_key;

  -- A missing or unparseable setting means the limit is unknown, and an unknown limit must
  -- not read as "no limit". Everything else here is written so that the failure mode is a
  -- refused insert rather than an open door.
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

comment on function private.enforce_daily_limit() is
  'Refuses an insert that would exceed the per-author rolling 24 hour limit in '
  'private.settings. SECURITY DEFINER so the count includes rows the caller cannot see and '
  'so the threshold itself stays unreadable from a browser. Knows about practices, '
  'confirmations, comments, citations and reports; raises on any other table.';

revoke all on function private.enforce_daily_limit() from public;

-- Trigger names sort after `comments_check_thread`, which is the order that reads best: a
-- malformed reply is refused as malformed rather than as over quota.
create trigger comments_daily_limit
  before insert on public.comments
  for each row
  execute function private.enforce_daily_limit();

create trigger citations_daily_limit
  before insert on public.citations
  for each row
  execute function private.enforce_daily_limit();

create trigger reports_daily_limit
  before insert on public.reports
  for each row
  execute function private.enforce_daily_limit();
