-- Per-author rate limits, configured in private.settings and enforced by trigger.
--
-- What this is for, and what it is not
-- ------------------------------------
-- Not spam defence. Turnstile and mandatory email confirmation do that job at the door,
-- before an account exists. This is the floor under a volunteer moderation queue: one
-- account cannot put two hundred practices into it overnight, whether through malice, a
-- misfiring script, or somebody discovering the API and testing it enthusiastically. The
-- numbers are set where an honest contributor will never see them and an accident stops
-- being anyone's afternoon.
--
-- Why in Postgres and not in the form
-- -----------------------------------
-- PostgREST is a public endpoint. A limit enforced in TypeScript is a limit that applies
-- to people using our form, which is not the population it exists to bound.
--
-- Why the thresholds are rows and not literals
-- --------------------------------------------
-- Changing a limit should not require a migration, a review, and a deploy. Rate limits are
-- the kind of number that wants adjusting the first time real traffic arrives, and the
-- adjustment is one UPDATE by whoever is watching the queue. They live in private.settings,
-- which has no grants of any kind: nothing in a browser can read the limit it is subject
-- to, let alone change it.

insert into private.settings (key, value, note) values
  ('rate_limit_practices_per_day', '10',
   'Practices one author may submit per rolling 24 hours. Ten is far past any honest '
   'session -- a well-structured account takes the better part of an hour -- and well '
   'short of what would bury the moderation queue.'),

  ('rate_limit_confirmations_per_day', '50',
   'Still-works confirmations one account may file per rolling 24 hours. Higher than the '
   'practice limit because working through a listing and reporting on many practices in an '
   'afternoon is exactly the behaviour we want, and cheap to review.'),

  ('rate_limit_comments_per_day', '50',
   'Comments per author per rolling 24 hours. Seeded now so the vocabulary is in one place; '
   'the trigger arrives with the comments table.');

-- ── The limiter ─────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER for two reasons that pull the same way. It reads private.settings,
-- which no browser role can reach, and it must count *every* row the author has written --
-- pending, published and hidden alike. As INVOKER the count would run under the caller's
-- own row level security and a hidden practice would not be counted, so the fastest way
-- past the limit would be to get moderated.
--
-- Not a guard in the sense that private.protect_profile_columns() is a guard: it asks
-- "how many rows has this author written", never "who is running this statement", so the
-- DEFINER trap that makes current_user useless inside a definer function does not apply.
--
-- Static SQL per table rather than one dynamic query with the table name substituted in.
-- Two branches is a little more to read than a format() call and has no injection surface
-- at all, which for a function running as its owner is a trade worth making every time.

create function private.enforce_daily_limit()
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
  'so the threshold itself stays unreadable from a browser.';

revoke all on function private.enforce_daily_limit() from public;

create trigger practices_daily_limit
  before insert on public.practices
  for each row
  execute function private.enforce_daily_limit();

create trigger practice_confirmations_daily_limit
  before insert on public.practice_confirmations
  for each row
  execute function private.enforce_daily_limit();

-- private.settings keeps its complete absence of grants. It was created with row level
-- security enabled and nothing granted to anon or authenticated, and 002_exposure.test.sql
-- asserts that no table in the private schema is granted to either. Adding three rows
-- changes none of that; it is stated here because a rate limit a caller could read is a
-- rate limit a caller can plan around.
