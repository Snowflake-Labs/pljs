-- Stressor distilled from snowflake_cdc: int64 / BigInt losslessness.
--
-- WAL LSNs are uint64 and routinely exceed 2^53, so they cannot survive a trip
-- through a JS double. The mirror adapter (postgres/adapter.js) therefore binds
-- JS BigInt values directly -- "pljs marshals a JS BigInt to int8 losslessly" --
-- and reads int8 result columns back as BigInt. This locks down both halves of
-- that contract at the boundary values (INT64_MAX and a >2^53 magnitude), so a
-- future pljs change that silently routed int8 through a double would fail here.
DO $$
  const MAX = 9223372036854775807n;                       // INT64_MAX (> 2^53)
  const bound = pljs.execute('SELECT $1::int8 AS v', [MAX])[0].v;
  pljs.elog(NOTICE, 'bind: typeof=' + (typeof bound) + ' lossless=' + (bound === MAX));
  const eq = pljs.execute('SELECT ($1::int8 = 9223372036854775807) AS e', [MAX])[0].e;
  pljs.elog(NOTICE, 'bind sql_eq_max=' + eq);

  const r = pljs.execute("SELECT 9223372036854775807::int8 AS mx, 4611686018427387904::int8 AS p62")[0];
  pljs.elog(NOTICE, 'col mx: typeof=' + (typeof r.mx) + ' lossless=' + (r.mx === MAX));
  pljs.elog(NOTICE, 'col p62: typeof=' + (typeof r.p62) + ' lossless=' + (r.p62 === 4611686018427387904n));
$$ LANGUAGE pljs;
