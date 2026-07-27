-- Stressor distilled from snowflake_cdc: rich / nested type marshalling through
-- pljs.execute (jsonb, arrays, numeric, composite, uuid-as-text).
--
-- The mirror procedures move change rows as jsonb, text[]/int[] column lists and
-- numeric values across the JS boundary, so their conversions must be exact.
-- (uuid is surfaced as text -- a bare uuid datum does not round-trip through the
-- current pljs uuid conversion, so callers, like the CDC procedures, cast to
-- text; that quirk is recorded in PROVENANCE.md.)
DO $$
  const r = pljs.execute(
      'SELECT $1::jsonb AS j, $2::int[] AS a, $3::text[] AS t, $4::numeric AS n',
      [ {a: 1, b: [2, 3], c: {d: true}}, [1, 2, 3], ['x', 'y'], '12345.6789' ])[0];
  pljs.elog(NOTICE, 'jsonb.b[1]=' + r.j.b[1] + ' jsonb.c.d=' + r.j.c.d +
                    ' int[].sum=' + r.a.reduce((x, y) => x + y, 0) +
                    ' text[][1]=' + r.t[1] + ' numeric=' + r.n);

  const c = pljs.execute("SELECT ARRAY[10,20,30] AS arr, '11111111-2222-3333-4444-555555555555'::uuid::text AS id")[0];
  pljs.elog(NOTICE, 'arr.len=' + c.arr.length + ' arr[2]=' + c.arr[2] + ' uuid=' + c.id);
$$ LANGUAGE pljs;
