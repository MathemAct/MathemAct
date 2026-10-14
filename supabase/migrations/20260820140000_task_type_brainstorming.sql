-- Add 'brainstorming' to public.report_task_type.
--
-- Free-form idea generation that does not fit the more specific labels. The closest
-- existing label is 'conjecture_generation', but that is specifically about proposing
-- mathematical statements; brainstorming covers the earlier, looser phase of exploring
-- approaches, themes, or directions without yet committing to a formal claim.

alter type public.report_task_type
  add value if not exists 'brainstorming' before 'conjecture_generation';
