-- Adds `other` to the network entry category vocabulary.
--
-- Alone, and ahead of the column and the CHECK that use it, because **a new enum label cannot
-- be used in the transaction that adds it**. `ALTER TYPE ... ADD VALUE` is itself allowed
-- inside a transaction block, but resolving the literal 'other' against the type calls
-- enum_in() during parse analysis, and Postgres refuses that with "unsafe use of new value".
-- The constraint in 20260821100100 names 'other', so it belongs in a separate migration.
--
-- Same rule that gave `example_counterexample` and `brainstorming` a file each in schema
-- version 2. See docs/decisions.md.

-- Appended, so it sorts last in the type. `other` belongs at the end of a vocabulary in the
-- database for the same reason it sits at the end of the radio list on the form.
alter type public.network_category add value if not exists 'other';
