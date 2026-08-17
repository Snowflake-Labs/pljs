-- Schema for tools/pljs-memory-matrix.sh.
--
-- Defines every scenario the harness drives: successful conversions across the
-- type surface, failures that escape call_function, failures caught inside
-- JavaScript, and a health assertion used to prove the backend still returns
-- correct answers after a failure.
--
-- Loaded once before the pgbench run.  Everything is IF NOT EXISTS / OR REPLACE
-- so the harness can be re-run against a warm database.

CREATE EXTENSION IF NOT EXISTS pljs;

-- ---------------------------------------------------------------------------
-- bookkeeping
-- ---------------------------------------------------------------------------

-- A sequence, not a table counter: nextval() survives the subtransaction
-- rollback that every caught failure performs, so the call count stays honest.
CREATE SEQUENCE IF NOT EXISTS pljs_mm_calls;
-- Counted separately from pljs_mm_calls so the RSS budget can be scaled by how
-- much DDL churn actually ran; see the RSS verdict in pljs-memory-matrix.sh.
CREATE SEQUENCE IF NOT EXISTS pljs_mm_churn_iters;

CREATE TABLE IF NOT EXISTS pljs_mm_samples (
  sample_no  bigserial primary key,
  at         timestamptz not null,
  calls      bigint      not null,
  -- per-call contexts: must be 0 between calls, since no call is in flight
  ctx_call   bigint      not null,
  -- everything pljs owns, including the function/context caches
  ctx_all    bigint      not null,
  bytes_all  bigint      not null
);

CREATE TABLE IF NOT EXISTS pljs_mm_sink (a int);
CREATE TABLE IF NOT EXISTS pljs_mm_churn (a int, b text);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pljs_mm_comp') THEN
    CREATE TYPE pljs_mm_comp AS (i int, t text);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- success paths: one function per conversion family
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mm_int8(v bigint) RETURNS bigint AS $$
  return BigInt(v);
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_numeric(v numeric) RETURNS numeric AS $$
  return v;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_text(v text) RETURNS text AS $$
  return v + 'é中文';
$$ LANGUAGE pljs;

-- bytea arrives as a Uint8Array; echo the bytes back unchanged.
CREATE OR REPLACE FUNCTION mm_bytea(v bytea) RETURNS bytea AS $$
  const out = new Uint8Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i];
  return out;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_jsonb(v jsonb) RETURNS jsonb AS $$
  return { echo: v, nested: { a: [1, null, 3], b: { c: 'd' } } };
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_int_array() RETURNS int[] AS $$
  return [1, null, 3, 4];
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_text_array() RETURNS text[] AS $$
  return ['a', null, 'c'];
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_jsonb_array() RETURNS jsonb[] AS $$
  return [{ a: 1 }, null, { b: [2, 3] }];
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_array_null() RETURNS int[] AS $$
  return null;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_comp() RETURNS pljs_mm_comp AS $$
  return { i: 7, t: 'seven' };
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_srf_multi() RETURNS SETOF pljs_mm_comp AS $$
  for (let i = 0; i < 4; i++) pljs.return_next({ i: i, t: 'r' + i });
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_srf_single() RETURNS SETOF text AS $$
  for (let i = 0; i < 4; i++) pljs.return_next('v' + i);
$$ LANGUAGE pljs;

-- A NULL row inside a composite set.
CREATE OR REPLACE FUNCTION mm_srf_null_row() RETURNS SETOF pljs_mm_comp AS $$
  pljs.return_next({ i: 1, t: 'a' });
  pljs.return_next(null);
  pljs.return_next({ i: 2, t: 'b' });
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_timestamp(v timestamptz) RETURNS timestamptz AS $$
  return v;
$$ LANGUAGE pljs;

-- SPI: parameterised execute, a plan that is freed, and a plan that is not.
CREATE OR REPLACE FUNCTION mm_spi(n int) RETURNS bigint AS $$
  let acc = 0n;
  const plan = pljs.prepare('SELECT $1::bigint AS v', ['int8']);
  try {
    for (let i = 0; i < n; i++) {
      acc += BigInt(pljs.execute('SELECT $1::bigint AS v', [i])[0].v);
      acc += BigInt(plan.execute([i])[0].v);
    }
  } finally {
    plan.free();
  }
  return acc;
$$ LANGUAGE pljs;

-- Deliberately never freed: exercises the plan GC finalizer.
CREATE OR REPLACE FUNCTION mm_spi_unfreed() RETURNS bigint AS $$
  const plan = pljs.prepare('SELECT $1::bigint AS v', ['int8']);
  return BigInt(plan.execute([1])[0].v);
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mm_cursor(n int) RETURNS bigint AS $$
  const plan = pljs.prepare('SELECT i FROM generate_series(1, $1) i', ['int4']);
  let acc = 0n;
  try {
    const c = plan.cursor([n]);
    try {
      let row;
      while ((row = c.fetch())) acc += BigInt(row.i);
    } finally {
      c.close();
    }
  } finally {
    plan.free();
  }
  return acc;
$$ LANGUAGE pljs;

-- Non-atomic procedure with an in-function commit.
CREATE OR REPLACE PROCEDURE mm_commit(n int) LANGUAGE pljs AS $$
  for (let i = 0; i < n; i++) {
    pljs.execute('INSERT INTO pljs_mm_sink VALUES ($1)', [i]);
    pljs.commit();
  }
$$;

-- ---------------------------------------------------------------------------
-- failures that ESCAPE call_function (the leak path)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mmf_overflow_int4() RETURNS int4 AS $$
  return 2147483648;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_overflow_int8() RETURNS int8 AS $$
  return 2n ** 70n;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_nan() RETURNS int4 AS $$
  return NaN;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_infinity() RETURNS int4 AS $$
  return Infinity;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_bad_string() RETURNS int4 AS $$
  return 'not a number';
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_bytea_number() RETURNS bytea AS $$
  return 42;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_column_mismatch() RETURNS SETOF pljs_mm_comp AS $$
  pljs.return_next({ nosuchcolumn: 1, t: 'x' });
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_throw() RETURNS int4 AS $$
  throw new Error('mm: deliberate failure');
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_self_reference() RETURNS jsonb AS $$
  const o = { a: 1 };
  o.self = o;
  return o;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmf_deep_recursion() RETURNS int4 AS $$
  function r(n) { return r(n + 1); }
  return r(0);
$$ LANGUAGE pljs;

-- ---------------------------------------------------------------------------
-- failures CAUGHT inside JavaScript
-- ---------------------------------------------------------------------------

-- More than five caught errors in a single call.  Without FlushErrorState() in
-- every PG_CATCH the sixth PANICs the cluster with "ERRORDATA_STACK_SIZE
-- exceeded", so this is the highest-value scenario in the harness.  Ends with a
-- successful execute to prove the SPI connection and error state are still
-- usable after all that catching.
CREATE OR REPLACE FUNCTION mmc_many_caught(n int) RETURNS int AS $$
  let caught = 0;
  for (let i = 0; i < n; i++) {
    try { pljs.execute('SELECT 1/0'); } catch (e) { caught++; }
    try { pljs.execute('SELCT syntax error'); } catch (e) { caught++; }
    try { pljs.execute('SELECT * FROM no_such_table_mm'); } catch (e) { caught++; }
  }
  const after = pljs.execute('SELECT 99 AS v')[0].v;
  if (after !== 99) throw new Error('SPI unusable after catching: ' + after);
  return caught;
$$ LANGUAGE pljs;

-- Three levels of nested execute, failing at the innermost.
CREATE OR REPLACE FUNCTION mmc_nested_l1() RETURNS int AS $$
  pljs.execute('SELECT 1/0');
  return 0;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmc_nested_l2() RETURNS int AS $$
  return pljs.execute('SELECT mmc_nested_l1() AS v')[0].v;
$$ LANGUAGE pljs;

CREATE OR REPLACE FUNCTION mmc_nested() RETURNS text AS $$
  try {
    pljs.execute('SELECT mmc_nested_l2() AS v');
    return 'no error';
  } catch (e) {
    // The envelope carries the message and the SQLSTATE across both nested
    // boundaries; the property is sqlerrcode.
    return 'caught:' + (e.message ? 'msg' : 'nomsg') +
           ':' + (e.sqlerrcode ? e.sqlerrcode : 'nostate');
  }
$$ LANGUAGE pljs;

-- A caught error must roll back only its own write.
CREATE OR REPLACE FUNCTION mmc_subxact() RETURNS int AS $$
  pljs.execute('INSERT INTO pljs_mm_sink VALUES (1)');
  try {
    pljs.execute('INSERT INTO pljs_mm_sink VALUES (2)');
    pljs.execute('SELECT 1/0');
  } catch (e) { /* the VALUES (2) insert must be gone */ }
  return pljs.execute(
    'SELECT count(*)::int AS n FROM pljs_mm_sink WHERE a = 2')[0].n;
$$ LANGUAGE pljs;

-- ---------------------------------------------------------------------------
-- health assertion: run after every failure to prove correctness survives
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION mm_assert_healthy() RETURNS void AS $$
DECLARE
  got text;
BEGIN
  PERFORM nextval('pljs_mm_calls');

  IF mm_int8(9223372036854775807) <> 9223372036854775807 THEN
    RAISE EXCEPTION 'mm_assert_healthy: int8 boundary wrong: %',
      mm_int8(9223372036854775807);
  END IF;

  IF mm_text('x') <> 'xé中文' THEN
    RAISE EXCEPTION 'mm_assert_healthy: text wrong: %', mm_text('x');
  END IF;

  IF mm_bytea('\xdeadbeef'::bytea) <> '\xdeadbeef'::bytea THEN
    RAISE EXCEPTION 'mm_assert_healthy: bytea bytes lost: %',
      encode(mm_bytea('\xdeadbeef'::bytea), 'hex');
  END IF;

  IF mm_jsonb('{"k":1}'::jsonb) -> 'nested' -> 'a' <> '[1, null, 3]'::jsonb THEN
    RAISE EXCEPTION 'mm_assert_healthy: jsonb wrong: %', mm_jsonb('{"k":1}'::jsonb);
  END IF;

  IF mm_int_array() <> ARRAY[1, NULL, 3, 4]::int[] THEN
    RAISE EXCEPTION 'mm_assert_healthy: int[] wrong: %', mm_int_array()::text;
  END IF;

  IF mm_array_null() IS NOT NULL THEN
    RAISE EXCEPTION 'mm_assert_healthy: array NULL wrong';
  END IF;

  SELECT (mm_comp()).t INTO got;
  IF got <> 'seven' THEN
    RAISE EXCEPTION 'mm_assert_healthy: composite wrong: %', got;
  END IF;

  IF (SELECT count(*) FROM mm_srf_multi()) <> 4 THEN
    RAISE EXCEPTION 'mm_assert_healthy: SETOF count wrong';
  END IF;

  IF (SELECT count(*) FROM mm_srf_null_row() WHERE i IS NULL) <> 1 THEN
    RAISE EXCEPTION 'mm_assert_healthy: NULL row missing';
  END IF;

  IF (SELECT count(*) FROM mm_srf_single()) <> 4 THEN
    RAISE EXCEPTION 'mm_assert_healthy: single-column SETOF wrong count';
  END IF;
END $$ LANGUAGE plpgsql;

-- Records one memory sample.  Runs as its own transaction with no pljs call in
-- flight, so ctx_call must be 0 unless a call leaked one.
CREATE OR REPLACE FUNCTION mm_sample() RETURNS void AS $$
  INSERT INTO pljs_mm_samples (at, calls, ctx_call, ctx_all, bytes_all)
  SELECT clock_timestamp(),
         (SELECT last_value FROM pljs_mm_calls),
         count(*) FILTER (WHERE name LIKE 'PLJS Function Memory Context%'
                             OR name LIKE 'PLJS Set Returning Memory Context%'),
         count(*) FILTER (WHERE name LIKE 'PLJS%'),
         coalesce(sum(total_bytes) FILTER (WHERE name LIKE 'PLJS%'), 0)
    FROM pg_backend_memory_contexts;
$$ LANGUAGE sql;
