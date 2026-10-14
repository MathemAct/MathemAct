-- Add 'example_counterexample' to public.report_task_type.
--
-- "Produce example or counterexample" is a distinct mathematical goal: an author who asked
-- an AI to find a ring where X holds but Y fails is not doing 'computation' (that label
-- covers the tool activity of calculating or searching) and is not doing
-- 'conjecture_generation' (that label covers proposing the statement in the first place).
-- Without this label it would land in 'computation', which understates the mathematical
-- intent, or 'other', which loses it from the filter entirely.

alter type public.report_task_type
  add value if not exists 'example_counterexample' before 'other';
