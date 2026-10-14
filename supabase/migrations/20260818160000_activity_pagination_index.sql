-- The feed is paginated by keyset, so its index needs the tiebreaker the sort now carries.
--
-- `created_at` is nowhere near unique in public.activity, and that is not an edge case: a
-- trigger writes every row it produces inside one transaction, so a single comment lands two
-- rows sharing a timestamp to the microsecond, and 20260818140000 reconstructed whole
-- histories the same way. Ordering by that column alone is therefore not a total order, and
-- a page boundary landing inside a group of equal timestamps is exactly where a row gets
-- shown twice or skipped.
--
-- The reading layer now asks for `order by created_at desc, id desc` and resumes with
-- `created_at < c or (created_at = c and id < i)`. This index makes that an ordered scan
-- rather than a sort, and — more to the point — makes the resume condition a seek to the
-- right place instead of a walk from the top of the feed.
--
-- The partial index on inbound rows is left alone deliberately. It serves the unread count,
-- which is `count(*)` over a range and never orders by anything, so a third column would be
-- weight with nothing hanging on it.

drop index public.activity_subject_idx;

create index activity_subject_idx
  on public.activity (subject_id, created_at desc, id desc);

comment on index public.activity_subject_idx is
  'One person''s feed, newest first. The id is the keyset tiebreaker: timestamps in this '
  'table are shared by every row a single trigger wrote.';
