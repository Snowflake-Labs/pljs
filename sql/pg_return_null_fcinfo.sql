-- Regression test for the NULL-fcinfo crash in pljs_jsvalue_to_datum().
--
-- pljs.execute() binds its parameters by calling pljs_jsvalue_to_datum() with
-- fcinfo == NULL (see pljs_execute_params()). Two bind paths -- the bytea
-- "unrecognised value" fallback and the non-Date date/timestamp fallback --
-- originally used PG_RETURN_NULL(), which expands to
-- `fcinfo->isnull = true; return ...` and crashed the backend by dereferencing
-- the NULL fcinfo.
--
-- Those paths now reject an unconvertible value with a clean, catchable error
-- (instead of silently binding SQL NULL, which hid real binding mistakes) and
-- crucially never touch fcinfo -- so the backend must stay alive either way.

-- site 1: unrecognised "binary" JS value bound to bytea -> clean error, no crash.
DO $$
  function bind_bytea(v) {
    try { pljs.execute('SELECT $1::bytea AS b', [ v ]); return 'no error'; }
    catch (e) { return 'err'; }
  }
  // A Float64Array is a perfectly good byte source and now converts; it used to
  // be listed here as unconvertible, which encoded a gap rather than a contract.
  // What must still be rejected is a value with no byte representation at all.
  pljs.elog(NOTICE, 'bytea reject: ' + bind_bytea({}) + ' ' +
                    bind_bytea(42) + ' ' + bind_bytea(true));
  pljs.elog(NOTICE, 'typed arrays accepted: ' +
                    bind_bytea(new Float64Array([1, 2])) + ' ' +
                    bind_bytea(new BigInt64Array([1n])));
$$ LANGUAGE pljs;

-- site 2: non-Date JS value bound to date / timestamp -> clean error, no crash.
DO $$
  function bind(sql, v) {
    try { pljs.execute(sql, [ v ]); return 'no error'; }
    catch (e) { return 'err'; }
  }
  pljs.elog(NOTICE, 'date/timestamp reject: ' + bind('SELECT $1::date AS d', 12345) +
                    ' ' + bind('SELECT $1::timestamp AS t', {}));
$$ LANGUAGE pljs;

-- The backend survived both.
SELECT 1 AS alive;
