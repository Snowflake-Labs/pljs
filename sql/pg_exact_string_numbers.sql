-- Exact conversion of a JavaScript *string* into an integer or numeric.
--
-- INT2OID/INT4OID/INT8OID/NUMERICOID converted a non-BigInt value with QuickJS's
-- numeric coercion (JS_ToInt32/JS_ToInt64/JS_ToFloat64), which routes through an
-- IEEE-754 double.  A string carrying exact decimal text therefore lost
-- precision silently:
--
--   '9223372036854775807'            -> -9223372036854775808   (sign flip)
--   '9007199254740993'              ->  9007199254740992      (off by one)
--   '123456789012345678'            ->  123456789012345680    (only ~1.2e17)
--   '12345678901234567890.123456789' ->  12345678901234600000  (numeric)
--
-- This is the shape the snowflake_cdc adapter produces: runQuery() normalizes
-- every bigint result with String() precisely to avoid JS number loss, and those
-- strings are then bound back into bigint parameters and returned through bigint
-- result columns -- where they were silently corrupted again.
--
-- A string is now parsed by the target type's input function, which reads the
-- full decimal text exactly and raises on malformed or out-of-range input.
CREATE EXTENSION IF NOT EXISTS pljs;

-- 1) int8: exact at the extremes and past 2^53, on both bind and result paths.
DO $$
  const cases = ['9223372036854775807', '-9223372036854775808',
                 '9007199254740993', '123456789012345678', '0', '-1'];
  const bad = [];
  for (const s of cases) {
    const v = pljs.execute('SELECT CAST($1 AS BIGINT) AS v', [s])[0].v;
    if (String(v) !== s) { bad.push(s + ' -> ' + String(v)); }
  }
  pljs.elog(NOTICE, 'int8 string binds exact: ' + (bad.length === 0) +
                    (bad.length ? ' failures: ' + bad.join(', ') : ''));
$$ LANGUAGE pljs;

-- the bigint result column path (return_next of a stringified BigInt).
CREATE FUNCTION esi_bigcol() RETURNS TABLE(id bigint, k int) LANGUAGE pljs AS $$
  pljs.return_next({id: '9223372036854775807', k: 1});
  pljs.return_next({id: '9007199254740993', k: 2});
  pljs.return_next({id: '123456789012345678', k: 3});
$$;
SELECT k, id FROM esi_bigcol() ORDER BY k;

-- and a plain scalar return.
CREATE FUNCTION esi_bigscalar() RETURNS bigint LANGUAGE pljs AS $$
  return '9223372036854775807';
$$;
SELECT esi_bigscalar(), esi_bigscalar() = 9223372036854775807 AS exact;

-- 2) numeric: a string keeps a scale no double can represent.
CREATE FUNCTION esi_numeric() RETURNS numeric LANGUAGE pljs AS $$
  return '12345678901234567890.123456789';
$$;
SELECT esi_numeric(),
       esi_numeric() = 12345678901234567890.123456789 AS exact;
CREATE FUNCTION esi_numcol() RETURNS TABLE(v numeric, k int) LANGUAGE pljs AS $$
  pljs.return_next({v: '12345678901234567890.123456789', k: 1});
$$;
SELECT v FROM esi_numcol();

-- 3) malformed and out-of-range strings raise instead of yielding 0 or wrapping.
CREATE FUNCTION esi_bad_int4() RETURNS int LANGUAGE pljs AS $$ return 'abc'; $$;
CREATE FUNCTION esi_over_int4() RETURNS int LANGUAGE pljs AS $$ return '2147483648'; $$;
CREATE FUNCTION esi_over_int2() RETURNS smallint LANGUAGE pljs AS $$ return '40000'; $$;
CREATE FUNCTION esi_over_int8() RETURNS bigint LANGUAGE pljs AS $$ return '9223372036854775808'; $$;
CREATE FUNCTION esi_bad_num() RETURNS numeric LANGUAGE pljs AS $$ return 'not a number'; $$;
SELECT esi_bad_int4();
SELECT esi_over_int4();
SELECT esi_over_int2();
SELECT esi_over_int8();
SELECT esi_bad_num();

-- 4) ordinary forms are unchanged: BigInt stays exact, numbers still convert,
-- and surrounding whitespace is accepted by the input function as usual.
CREATE FUNCTION esi_bigint() RETURNS bigint LANGUAGE pljs AS $$ return 9223372036854775807n; $$;
CREATE FUNCTION esi_number() RETURNS int LANGUAGE pljs AS $$ return 42; $$;
CREATE FUNCTION esi_float() RETURNS numeric LANGUAGE pljs AS $$ return 1.5; $$;
CREATE FUNCTION esi_padded() RETURNS int LANGUAGE pljs AS $$ return '  7  '; $$;
CREATE FUNCTION esi_int2ok() RETURNS smallint LANGUAGE pljs AS $$ return '-32768'; $$;
SELECT esi_bigint(), esi_number(), esi_float(), esi_padded(), esi_int2ok();

-- 5) NULL handling is untouched by the string path.
CREATE FUNCTION esi_null() RETURNS bigint LANGUAGE pljs AS $$ return null; $$;
SELECT esi_null() IS NULL AS null_ok;
DO $$
  pljs.elog(NOTICE, 'bind null int8 -> ' +
    (pljs.execute('SELECT $1::int8 AS v', [null])[0].v === null));
$$ LANGUAGE pljs;

DROP FUNCTION esi_bigcol, esi_bigscalar, esi_numeric, esi_numcol, esi_bad_int4,
  esi_over_int4, esi_over_int2, esi_over_int8, esi_bad_num, esi_bigint,
  esi_number, esi_float, esi_padded, esi_int2ok, esi_null;
