-- The signup form carries a pseudonym preference, so the profile trigger has to read it.
--
-- Without this, someone who ticks "show a pseudonym instead of my name" gets a profile with
-- is_pseudonym false and has to go and set it again after confirming their email. That is a
-- small thing everywhere except here: the people most likely to tick that box are the ones
-- for whom the gap between signing up and fixing it is the risk.
--
-- Only two keys are ever read out of raw_user_meta_data, and both name columns the user is
-- allowed to write anyway. That restraint is the security property. raw_user_meta_data is
-- supplied by the browser at signup and is entirely under the caller's control -- a version
-- of this that looped over the object, or read `role`, would hand out moderator accounts to
-- anyone who could read the network tab.

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name  text;
  v_is_pseudonym  boolean;
begin
  v_display_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');

  -- The default display name is deliberately NOT derived from the email address. The local
  -- part of an address is often a full name, and this site must work for someone whose
  -- reason for being here is that they cannot afford to be identified.
  if v_display_name is null then
    v_display_name := 'Member ' || left(replace(new.id::text, '-', ''), 8);
  end if;

  -- Compared as text rather than cast to boolean. A cast throws on anything that is not a
  -- recognised boolean literal, and the value arrives from a browser: a malformed one must
  -- mean "not a pseudonym", not "signup failed".
  v_is_pseudonym :=
    lower(coalesce(new.raw_user_meta_data ->> 'is_pseudonym', '')) in ('true', 't', '1', 'yes');

  insert into public.profiles (id, display_name, is_pseudonym)
  values (new.id, left(v_display_name, 80), v_is_pseudonym)
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function private.handle_new_user() is
  'Creates the public.profiles row for a new account, reading display_name and is_pseudonym '
  'from signup metadata. Never derives a display name from the email address, and never '
  'reads any other key out of raw_user_meta_data.';

revoke all on function private.handle_new_user() from public;
