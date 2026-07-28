-- Type conversions not already covered by types.sql.
--
-- types.sql covers int2/4/8, float8<->numeric, and text<->int4 (incl. the
-- invalid-cast error). This adds oid (via regclass) and array element casting
-- (int4[] <-> text[]), which the mirror/DDL code touches when it reads
-- pg_catalog oids and column-name arrays.
DO $$
  const oid = pljs.execute("SELECT 'pg_class'::regclass::oid AS o")[0].o;
  pljs.elog(NOTICE, 'oid: type=' + (typeof oid) + ' positive=' + (oid > 0));
  const nm = pljs.execute('SELECT $1::oid::regclass::text AS n', [oid])[0].n;
  pljs.elog(NOTICE, 'oid->regclass name=' + nm);

  const ia = pljs.execute('SELECT $1::int4[] AS a', [[10, 20, 30]])[0].a;
  pljs.elog(NOTICE, 'int4[]: isArr=' + Array.isArray(ia) + ' sum=' + ia.reduce((x, y) => x + y, 0));

  const ta = pljs.execute('SELECT $1::text[] AS a', [['a', 'b', 'c']])[0].a;
  pljs.elog(NOTICE, 'text[]: isArr=' + Array.isArray(ta) + ' join=' + ta.join('-'));

  const x = pljs.execute('SELECT ARRAY[1,2,3]::int4[]::text[] AS a')[0].a;
  pljs.elog(NOTICE, 'int4[]->text[]: [0]type=' + (typeof x[0]) + ' join=' + x.join(','));
$$ LANGUAGE pljs;
