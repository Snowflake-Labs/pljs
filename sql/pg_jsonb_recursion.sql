-- The JS -> jsonb conversion (jsonb_object_from_object / jsonb_array_from_array)
-- recursed into every nested container with no cycle detection and no depth
-- bound, so a cyclic or very deep value overflowed the C stack and SIGSEGV'd the
-- backend.  All four cases below crashed the server.
--
-- Note the QuickJS stack limit does not cover this: the recursion is in pljs's
-- own C frames, not in the interpreter, so it is invisible to the engine's own
-- stack accounting.
--
-- A plain `function` value crashed too, because enumerating its properties
-- reaches `prototype`, whose `constructor` points back at the function.
-- JSON.stringify() omits function-valued properties (and renders a function in
-- an array as null); pljs now matches that instead of recursing.
CREATE EXTENSION IF NOT EXISTS pljs;

-- 1) Self-referencing object.
CREATE FUNCTION jsonb_circular_object() RETURNS jsonb AS $$
  var o = {a: 1};
  o.self = o;
  return o;
$$ LANGUAGE pljs;

SELECT jsonb_circular_object();

-- 2) Self-referencing array.
CREATE FUNCTION jsonb_circular_array() RETURNS jsonb AS $$
  var a = [1];
  a.push(a);
  return a;
$$ LANGUAGE pljs;

SELECT jsonb_circular_array();

-- 3) A cycle reached indirectly, several levels down.
CREATE FUNCTION jsonb_circular_deep() RETURNS jsonb AS $$
  var root = {a: {b: {c: {}}}};
  root.a.b.c.back = root.a;
  return root;
$$ LANGUAGE pljs;

SELECT jsonb_circular_deep();

-- 4) Acyclic but deeper than the C stack can take.
CREATE FUNCTION jsonb_deep_nesting(depth int) RETURNS jsonb AS $$
  var root = {}, cur = root;
  for (var i = 0; i < depth; i++) { cur.n = {}; cur = cur.n; }
  return root;
$$ LANGUAGE pljs;

SELECT jsonb_deep_nesting(100000);

-- Nesting inside the limit still converts.
SELECT jsonb_deep_nesting(50) IS NOT NULL AS depth_50_ok;

-- 5) Function values: omitted as an object property, null as an array element
-- (JSON.stringify semantics), and no longer a crash.
CREATE FUNCTION jsonb_with_function() RETURNS jsonb AS $$
  return {keep: 1, fn: function() { return 1; }, arr: [1, function() {}, 3]};
$$ LANGUAGE pljs;

SELECT jsonb_with_function();

-- A bare function as the whole result.
CREATE FUNCTION jsonb_bare_function() RETURNS jsonb AS $$
  return function() {};
$$ LANGUAGE pljs;

SELECT jsonb_bare_function();

-- Sharing one object at several places is not a cycle and must still work:
-- the guard tracks the recursion stack, not every value ever visited.
CREATE FUNCTION jsonb_shared_not_circular() RETURNS jsonb AS $$
  var shared = {v: 7};
  return {a: shared, b: shared, c: [shared, shared]};
$$ LANGUAGE pljs;

SELECT jsonb_shared_not_circular();

-- The backend survives, and a rejected conversion leaves it usable (the
-- conversion memory context is dropped on the error path).
DO $$
  var caught = 0;
  for (var i = 0; i < 50; i++) {
    var o = {};
    o.self = o;
    try { pljs.execute('SELECT $1::jsonb', [o]); } catch (e) { caught++; }
  }
  pljs.elog(NOTICE, 'rejected ' + caught + ' circular conversions, still alive');
$$ LANGUAGE pljs;

SELECT 'backend still usable' AS status;

DROP FUNCTION jsonb_circular_object();
DROP FUNCTION jsonb_circular_array();
DROP FUNCTION jsonb_circular_deep();
DROP FUNCTION jsonb_deep_nesting(int);
DROP FUNCTION jsonb_with_function();
DROP FUNCTION jsonb_bare_function();
DROP FUNCTION jsonb_shared_not_circular();
