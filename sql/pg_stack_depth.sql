-- Regression: deep / unbounded JS recursion must raise a catchable
-- "stack overflow" error and leave the backend alive -- never crash it with a
-- C-stack SIGSEGV.
--
-- QuickJS only performs stack checks when built with CONFIG_STACK_CHECK, and
-- even then pljs previously relied on the vendored JS_DEFAULT_STACK_SIZE and
-- never set a limit explicitly.  pljs now sets an explicit QuickJS stack budget
-- (half of max_stack_depth, floored) in _PG_init, so pure-JS recursion trips
-- QuickJS's guard well before PostgreSQL's own C-stack limit and the kernel
-- stack limit are reached.
CREATE EXTENSION IF NOT EXISTS pljs;

-- Unbounded self-recursion in an anonymous block.  Use terse verbosity: the
-- InternalError stack trace carried in DETAIL is machine dependent (its length
-- depends on frame size), so it must not appear in the portable expected file.
\set VERBOSITY terse
DO $$ function r(n) { return r(n + 1); } r(0); $$ LANGUAGE pljs;
\set VERBOSITY default

-- The backend survived the overflow and is still usable.
SELECT 1 AS alive;

-- The overflow surfaces as an ordinary, catchable JS error.
CREATE FUNCTION deep_recurse() RETURNS text LANGUAGE pljs AS $$
  function r(n) { return r(n + 1); }
  try { r(0); }
  catch (e) { return "caught: " + e.name + ": " + e.message; }
  return "no error";
$$;
SELECT deep_recurse();

-- Mutual JS<->SQL recursion is bounded as well: PostgreSQL's check_stack_depth
-- stops it and the error is caught and unwound at every level, so the top-level
-- call returns cleanly and the backend stays alive.
CREATE FUNCTION mutual() RETURNS text LANGUAGE pljs AS $$
  try { return pljs.execute("SELECT mutual()")[0].mutual; }
  catch (e) { return "depth-limited"; }
$$;
SELECT mutual();
SELECT 1 AS alive_after_mutual;

DROP FUNCTION mutual();
DROP FUNCTION deep_recurse();
