-- public.confirmation_verdict — two more values, because "does this still work?" is the
-- wrong question to ask about a report that says it did not work.
--
-- The confirmation control has asked one question since it was built: "Does this still
-- work?", with answers "It still works" and "It no longer works". On a report whose
-- outcome is 'failed' that question is incoherent, and every possible answer to it is a
-- claim the reader did not make. Somebody who rechecks a failure and finds it still fails
-- has done exactly the work this feature exists to collect, and had no way to say so.
--
-- So there are two questions, chosen by the report's outcome:
--
--   outcome 'worked' or 'partial'  ->  Does this still work?
--                                        still_works | no_longer_works
--   outcome 'failed'               ->  Does this still not work?
--                                        still_fails | now_works
--
-- Four values rather than two neutral ones ('reproduced' / 'changed') because the corpus
-- is downloadable and every row in it should stand alone. A researcher reading
-- latest_verdict out of the CSV must be able to tell which question was asked without
-- joining the report back to find its outcome; 'changed' alone cannot say whether a tool
-- stopped working or started.
--
-- Nothing here is a rename and nothing is reinterpreted: 'still_works' and
-- 'no_longer_works' keep the exact meaning they were written with, and every row already
-- carrying them sits on a report whose outcome is 'worked' or 'partial'.

-- ── Why this is its own migration file ──────────────────────────────────────────────
-- ALTER TYPE ... ADD VALUE inside a transaction block adds the value, but the value
-- cannot be *used* until that transaction commits. The Supabase CLI runs each migration
-- file in a transaction, so the trigger and the view that compare against these two
-- literals have to be in the next file, not this one. Putting them together fails with
-- "unsafe use of new value of enum type" — at push time, which is the good case, but the
-- fix is a second file either way.

alter type public.confirmation_verdict add value if not exists 'still_fails'
  after 'no_longer_works';

alter type public.confirmation_verdict add value if not exists 'now_works'
  after 'still_fails';

comment on type public.confirmation_verdict is
  'A reader''s report on whether a report still describes what happens. Which pair of '
  'values applies is decided by the report''s outcome: still_works/no_longer_works when it '
  'worked or partly worked, still_fails/now_works when it did not. Drives the tombstone.';
