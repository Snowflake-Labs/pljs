-- NB: parts of this file record CURRENT (incorrect) behaviour, not a contract:
-- int8 values beyond 2^53 wrap or round here.  The expected output changes when
-- the range and exactness checks land, and that diff is the point.
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

  // A numeric *string* binds into BIGINT exactly, because a string is parsed by
  // int8's input function rather than routed through a double.  This is the
  // shape the adapter actually produces: runQuery() normalizes every BigInt
  // result with String(), and those strings are then bound back into bigint
  // parameters and bigint result columns.  It used to wrap INT64_MAX to
  // INT64_MIN and to lose digits from ~2^53 upward (e.g. '123456789012345678'
  // came back two off), so this asserts exactness rather than pinning the loss.
  const viaStr = pljs.execute('SELECT CAST($1 AS BIGINT) AS v', ['9223372036854775807'])[0].v;
  pljs.elog(NOTICE, 'string-bind int64_max: str=' + String(viaStr) + ' lossless=' + (viaStr === 9223372036854775807n));
  const viaStr2 = pljs.execute('SELECT CAST($1 AS BIGINT) AS v', ['123456789012345678'])[0].v;
  pljs.elog(NOTICE, 'string-bind 1.2e17: str=' + String(viaStr2) + ' lossless=' + (viaStr2 === 123456789012345678n));
$$ LANGUAGE pljs;
