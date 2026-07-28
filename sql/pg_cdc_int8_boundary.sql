-- snowflake_cdc type-boundary matrix: int8 / BigInt (extends pg_bigint_lsn).
--
-- int8 is the dominant control-plane type in the mirror procedures: WAL LSNs,
-- operation_id, snapshot_lsn and table_id all cross the JS boundary as bigint,
-- bound via CAST(? AS BIGINT) (postgres/adapter.js, apply_change_batches/*.js)
-- and read back as JS BigInt, which the adapter normalizes with String() to
-- avoid IEEE-754 loss (adapter.js runQuery). This locks the whole int8 boundary
-- at the extremes and NULL, plus the bigint[] VALUES-pair shape from
-- live_view.js, so a future pljs change routing int8 through a double fails here.
DO $$
  function b(x){ return pljs.execute('SELECT CAST($1 AS BIGINT) AS v', [x])[0].v; }
  const cases = [
    ['int64_max', 9223372036854775807n],
    ['int64_min', -9223372036854775808n],
    ['zero',      0n],
    ['neg_one',   -1n],
    ['pow53_m1',  9007199254740991n],
    ['pow53_p1',  9007199254740993n],
    ['big',       1234567890123456789n],
  ];
  for (const [name, v] of cases) {
    const r = b(v);
    pljs.elog(NOTICE, name + ': typeof=' + (typeof r) + ' str=' + String(r) + ' lossless=' + (r === v));
  }

  // bigint[] VALUES-pair shape: (CAST(? AS BIGINT), CAST(? AS BIGINT)) (live_view.js)
  const pair = pljs.execute(
    'SELECT a, b FROM (VALUES (CAST($1 AS BIGINT), CAST($2 AS BIGINT))) AS v(a, b)',
    [9223372036854775807n, -9223372036854775808n])[0];
  pljs.elog(NOTICE, 'pair: a=' + String(pair.a) + ' b=' + String(pair.b));

  // NULL both directions
  const bn = pljs.execute('SELECT CAST($1 AS BIGINT) AS v', [null])[0].v;
  const rn = pljs.execute('SELECT NULL::int8 AS v')[0].v;
  pljs.elog(NOTICE, 'null: bindNull=' + (bn === null) + ' readNull=' + (rn === null));

  // WHY BigInt and not a numeric string: pin how a JS string binds into BIGINT.
  const viaStr = pljs.execute('SELECT CAST($1 AS BIGINT) AS v', ['9223372036854775807'])[0].v;
  pljs.elog(NOTICE, 'string-bind int64_max: str=' + String(viaStr) + ' lossless=' + (viaStr === 9223372036854775807n));
$$ LANGUAGE pljs;
