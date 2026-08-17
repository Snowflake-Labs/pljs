-- NB: some expected output below is QuickJS's own wording ("out of memory",
-- "stack overflow"), which is not part of any stable interface -- it is pinned
-- by the vendored deps/quickjs revision and will churn if that is bumped.  If a
-- QuickJS upgrade fails here, check the message text before assuming a
-- behaviour regression.
-- Regression: enumerating a JS object's keys must free the property table and
-- the atom references that JS_GetOwnPropertyNames() hands back.
--
-- Two hot paths enumerate object keys and previously freed neither the
-- js_malloc'd JSPropertyEnum table nor the per-property atom references:
--   * jsonb_object_from_object()                 -- every JS object -> jsonb
--     conversion, i.e. any function returning jsonb of an object;
--   * pljs_jsvalue_object_contains_all_column_names() -- every composite /
--     SETOF return_next() row.
-- The leaked table counts against the QuickJS runtime memory limit and is never
-- reclaimed until the backend exits, so a long-running backend slowly exhausts
-- pljs.memory_limit and then fails every JS call with "out of memory".
--
-- Under a tight cap (64MB, the minimum) the loops below leaked ~128MB and OOM'd
-- before the fix (~ one table per conversion / per row, sized by the object's
-- key count); they must now complete.  Objects are deliberately given many keys
-- so the pre-fix leak dwarfs the cap with a wide, platform-independent margin
-- while the iteration counts stay small and fast.
--
-- Instrument, and why this one is not measured with pg_backend_memory_contexts:
-- the leak is on the QuickJS heap, which that view cannot see at all, so a test
-- built on it would pass whether or not the leak is fixed.  pljs.memory_limit is
-- the only SQL-visible instrument that counts QuickJS allocations.
--
-- Verified to discriminate rather than assumed: with the two property-table
-- release sites disabled in src/types.c, this file fails; with them in place it
-- passes.  The 64MB cap is the GUC's minimum, so the margin cannot be widened by
-- lowering it -- the objects' key counts are the lever instead.
CREATE EXTENSION IF NOT EXISTS pljs;
SET pljs.memory_limit = 64;

-- 1) JS object -> jsonb (jsonb_object_from_object), reached via return_next of a
-- SETOF jsonb.  The fat object is built once and converted per row, so this is
-- cheap to run but leaks one table per conversion.  20k rows of an ~800-key
-- object is ~128MB of leaked tables vs the 64MB cap -> OOM pre-fix.
CREATE FUNCTION jsonb_obj_leak(n int) RETURNS SETOF jsonb LANGUAGE pljs AS $$
  var o = {};
  for (var k = 0; k < 800; k++) o["c" + k] = k;
  for (var i = 0; i < n; i++) pljs.return_next(o);
$$;
SELECT count(*) = 20000 AS jsonb_object_return_ok FROM jsonb_obj_leak(20000);

-- 2) composite return_next (contains_all_column_names): the enumerated table is
-- sized by *all* of the object's own keys, not just the target columns, so a
-- result fed a fat object leaks a big table per row.  20k rows of a
-- ~800-key object is ~128MB of leaked tables vs the 64MB cap -> OOM pre-fix.
--
-- NB: this must declare two or more columns.  A single-column set is not
-- "composite", so return_next() takes the scalar path and never reaches
-- pljs_jsvalue_object_contains_all_column_names() -- the very function whose
-- leak this case exists to cover.  (One column also silently stored 0 for every
-- row, because the whole object went through the int4 conversion; the value
-- assertions below would now catch that.)
CREATE FUNCTION composite_obj_leak(n int) RETURNS TABLE(a int, b int) LANGUAGE pljs AS $$
  var o = {a: 0, b: 0};
  for (var k = 0; k < 800; k++) o["x" + k] = k;
  for (var i = 0; i < n; i++) { o.a = i; o.b = i + 1; pljs.return_next(o); }
$$;
SELECT count(*) = 20000 AS composite_return_next_ok,
       min(a) = 0 AND max(a) = 19999 AS composite_values_ok
  FROM composite_obj_leak(20000);

-- The backend survived both loops and is still usable.
SELECT 1 AS alive;

RESET pljs.memory_limit;
DROP FUNCTION jsonb_obj_leak(int);
DROP FUNCTION composite_obj_leak(int);
