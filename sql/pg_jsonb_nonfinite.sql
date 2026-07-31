-- jsonb has no representation for NaN or +/-Infinity, and neither does JSON.
-- The conversion used to push whatever float8_numeric() produced, so the datum
-- rendered as `{"v": NaN}` -- text that is not valid JSON, cannot be re-parsed
-- by jsonb_in, and breaks pg_dump/restore and every client JSON parser.  Such a
-- value could be written into a table and only fail later, somewhere else.
--
-- JSON.stringify() emits null for these, which is also what pljs's own `json`
-- conversion does; jsonb now agrees.
CREATE EXTENSION IF NOT EXISTS pljs;

CREATE FUNCTION jsonb_nonfinite() RETURNS jsonb AS $$
  return {nan: NaN, inf: Infinity, ninf: -Infinity, ok: 1.5, zero: 0, negzero: -0};
$$ LANGUAGE pljs;

SELECT jsonb_nonfinite();

-- The critical property: the result is valid jsonb, so it survives a text
-- round-trip.  This failed before the fix.
SELECT jsonb_nonfinite()::text::jsonb = jsonb_nonfinite() AS reparses;

-- Same in an array and nested.
CREATE FUNCTION jsonb_nonfinite_nested() RETURNS jsonb AS $$
  return [NaN, [Infinity], {deep: -Infinity}];
$$ LANGUAGE pljs;

SELECT jsonb_nonfinite_nested();
SELECT jsonb_nonfinite_nested()::text::jsonb = jsonb_nonfinite_nested() AS reparses;

-- As a bare scalar result.
CREATE FUNCTION jsonb_bare_nan() RETURNS jsonb AS $$ return NaN; $$ LANGUAGE pljs;
SELECT jsonb_bare_nan(), jsonb_typeof(jsonb_bare_nan()) AS typ;

-- And the same through a bind parameter, which is how the mirror procedures
-- would hit it.
DO $$
  var r = pljs.execute('SELECT $1::jsonb AS j', [{a: 1 / 0, b: Math.sqrt(-1)}]);
  pljs.elog(NOTICE, 'bound: ' + JSON.stringify(r[0].j));
$$ LANGUAGE pljs;

-- It can be stored and read back.
CREATE TABLE jsonb_nonfinite_t (j jsonb);
INSERT INTO jsonb_nonfinite_t SELECT jsonb_nonfinite();
SELECT j -> 'nan' IS NOT NULL AS key_present,
       jsonb_typeof(j -> 'nan') AS nan_type,
       j ->> 'ok' AS ok
FROM jsonb_nonfinite_t;

DROP TABLE jsonb_nonfinite_t;
DROP FUNCTION jsonb_nonfinite();
DROP FUNCTION jsonb_nonfinite_nested();
DROP FUNCTION jsonb_bare_nan();
