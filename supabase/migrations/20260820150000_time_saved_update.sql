-- Revise the time_saved vocabulary: add 'about_an_hour', rename 'full_day' to 'about_a_day'.
-- The corpus was emptied in 20260820100000 so there are no rows to migrate.
-- The RPCs take time_saved as a plain text parameter; only the column constraint changes.

alter table public.reports
  drop constraint reports_time_saved_values,
  add constraint reports_time_saved_values
    check (time_saved in (
      'none', 'few_minutes', 'about_an_hour', 'few_hours', 'about_a_day',
      'few_days', 'about_a_week', 'more', 'cost_more'
    ));
