-- Adds ist.ac.at to private.manual_domains and re-badges any existing confirmed
-- user whose email belongs to that domain.
--
-- ISTA rebranded from "IST Austria" to "ISTA" in 2022, and their primary domain
-- moved from ist.ac.at to ista.ac.at. The old domain ist.ac.at does not appear in
-- the ror_domains table (the ROR record for 03gnh5541 carries ista.ac.at, not the
-- legacy address), so existing users whose confirmed email ends in @ist.ac.at
-- receive no institutional badge. This manual entry closes that gap.
-- Evidence: https://ror.org/03gnh5541 is the ROR record for the Institute of
-- Science and Technology Austria. The ist.ac.at domain is confirmed as the
-- institution's former address; see https://ista.ac.at/en/institute/ and archived
-- pages at ist.ac.at prior to 2022.

-- Ensure ISTA is in ror_institutions. The ROR dump loaded into production predates
-- ISTA's entry (or the entry arrived after the last loader run). ON CONFLICT DO NOTHING
-- makes this safe to leave in place once the loader catches up.
insert into private.ror_institutions (ror_id, name, country_code, country_name)
values ('03gnh5541', 'Institute of Science and Technology Austria', 'AT', 'Austria')
on conflict (ror_id) do nothing;

insert into private.manual_domains (domain, ror_id, added_by, evidence) values
  ('ist.ac.at', '03gnh5541', 'emma.zanoli',
   'IST Austria / ISTA (Institute of Science and Technology Austria), ROR 03gnh5541, '
   'Klosterneuburg, AT. ist.ac.at was the primary domain before the 2022 rebrand to '
   'ista.ac.at. Added because a confirmed user at this legacy domain received no '
   'institutional badge. See https://ror.org/03gnh5541 and https://ista.ac.at/.');

-- Re-badge every confirmed user whose email is at ist.ac.at.
-- Mirrors the logic in private.sync_institution_from_email(), which fires only on
-- UPDATE of auth.users and cannot back-fill users who signed up before this entry.
do $$
declare
  v_match   private.institution_match;
  v_name    text;
  v_country text;
begin
  v_match := private.match_institution('ist.ac.at');

  if v_match.ror_id is null then
    raise exception
      'ist.ac.at did not resolve after insert into manual_domains — '
      'check that private.match_institution is up to date';
  end if;

  select i.name, i.country_name
    into v_name, v_country
    from private.ror_institutions i
   where i.ror_id = v_match.ror_id;

  if v_name is null or v_country is null then
    raise exception
      'ROR record % not found in ror_institutions (name=%, country=%). '
      'Run the ROR loader (scripts/load-ror.mjs) and retry.',
      v_match.ror_id, v_name, v_country;
  end if;

  update public.profiles p
     set institution_ror_id      = v_match.ror_id,
         institution_name        = v_name,
         institution_country     = v_country,
         institution_verified_at = now(),
         institution_source      = v_match.source,
         updated_at              = now()
    from auth.users u
   where p.id = u.id
     and lower(split_part(u.email, '@', 2)) = 'ist.ac.at'
     and u.email_confirmed_at is not null;

  raise notice 'ISTA re-badge complete: % row(s) updated', found::int;
end;
$$;