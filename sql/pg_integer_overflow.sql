-- Out-of-range integers are rejected instead of wrapping silently.
--
-- QuickJS's JS_ToInt32/JS_ToInt64 wrap modulo the word size and JS_ToBigInt64
-- truncates to the low 64 bits, all without reporting anything, so a value the
-- target type cannot hold was silently stored as a *different* number:
--
--   int4    <- 2147483648            ->  -2147483648   (wrapped)
--   int2    <- 40000                 ->  -25536        (wrapped)
--   int4    <- 12345678901234567890n ->  -350287150    (truncated)
--   int8    <- 2n**70n               ->  0             (truncated)
--   int8    <- 1e30                  ->  5076964154930102272
--   int4    <- NaN / Infinity        ->  0
--
-- PostgreSQL raises "integer out of range" for the equivalent cast, and quietly
-- storing a different value is the worst outcome for a data pipeline, so the
-- range is now enforced.  Fractions still truncate toward zero, which is the
-- established JavaScript conversion behaviour; only the range is new.
CREATE EXTENSION IF NOT EXISTS pljs;

-- 1) numbers beyond the target range raise.
CREATE FUNCTION ior_i4_over() RETURNS int LANGUAGE pljs AS $$ return 2147483648; $$;
CREATE FUNCTION ior_i4_under() RETURNS int LANGUAGE pljs AS $$ return -2147483649; $$;
CREATE FUNCTION ior_i2_over() RETURNS smallint LANGUAGE pljs AS $$ return 40000; $$;
CREATE FUNCTION ior_i8_over() RETURNS bigint LANGUAGE pljs AS $$ return 1e30; $$;
SELECT ior_i4_over();
SELECT ior_i4_under();
SELECT ior_i2_over();
SELECT ior_i8_over();

-- 2) BigInts beyond the target range raise, including past int64 entirely.
CREATE FUNCTION ior_big_i4() RETURNS int LANGUAGE pljs AS $$ return 12345678901234567890n; $$;
CREATE FUNCTION ior_big_i8() RETURNS bigint LANGUAGE pljs AS $$ return 2n ** 70n; $$;
CREATE FUNCTION ior_big_i2() RETURNS smallint LANGUAGE pljs AS $$ return 40000n; $$;
SELECT ior_big_i4();
SELECT ior_big_i8();
SELECT ior_big_i2();

-- 3) NaN and Infinity are not integers and say so.
CREATE FUNCTION ior_nan() RETURNS int LANGUAGE pljs AS $$ return NaN; $$;
CREATE FUNCTION ior_inf() RETURNS int LANGUAGE pljs AS $$ return Infinity; $$;
CREATE FUNCTION ior_ninf() RETURNS bigint LANGUAGE pljs AS $$ return -Infinity; $$;
SELECT ior_nan();
SELECT ior_inf();
SELECT ior_ninf();

-- 4) the exact boundaries must still convert.
CREATE FUNCTION ior_i2_min() RETURNS smallint LANGUAGE pljs AS $$ return -32768; $$;
CREATE FUNCTION ior_i2_max() RETURNS smallint LANGUAGE pljs AS $$ return 32767; $$;
CREATE FUNCTION ior_i4_min() RETURNS int LANGUAGE pljs AS $$ return -2147483648; $$;
CREATE FUNCTION ior_i4_max() RETURNS int LANGUAGE pljs AS $$ return 2147483647; $$;
CREATE FUNCTION ior_i8_min() RETURNS bigint LANGUAGE pljs AS $$ return -9223372036854775808n; $$;
CREATE FUNCTION ior_i8_max() RETURNS bigint LANGUAGE pljs AS $$ return 9223372036854775807n; $$;
SELECT ior_i2_min(), ior_i2_max(), ior_i4_min(), ior_i4_max();
SELECT ior_i8_min(), ior_i8_max();

-- 2^53 as a plain number is representable and must be unaffected.
CREATE FUNCTION ior_p53() RETURNS bigint LANGUAGE pljs AS $$ return 9007199254740992; $$;
SELECT ior_p53();

-- 5) fractions keep truncating toward zero (unchanged behaviour).
CREATE FUNCTION ior_frac_pos() RETURNS int LANGUAGE pljs AS $$ return 1.7; $$;
CREATE FUNCTION ior_frac_neg() RETURNS int LANGUAGE pljs AS $$ return -1.7; $$;
SELECT ior_frac_pos(), ior_frac_neg();
-- and a fraction that truncates back into range is accepted.
CREATE FUNCTION ior_frac_edge() RETURNS smallint LANGUAGE pljs AS $$ return 32767.9; $$;
SELECT ior_frac_edge();

-- 6) the same checks apply on the bind path (fcinfo = NULL).
DO $$
  const cases = [['int4', 2147483648], ['int2', 40000], ['int8', 1e30],
                 ['int4', NaN], ['int8', 2n ** 70n]];
  for (const [t, v] of cases) {
    try {
      pljs.execute('SELECT $1::' + t + ' AS v', [v]);
      pljs.elog(NOTICE, t + ' unexpectedly accepted an out-of-range value');
    } catch (e) {
      pljs.elog(NOTICE, t + ' rejected: ' + (e.message.indexOf('range') >= 0 ||
                                             e.message.indexOf('NaN') >= 0));
    }
  }
$$ LANGUAGE pljs;

-- 7) NULL is still NULL, not an out-of-range value.
CREATE FUNCTION ior_null() RETURNS int LANGUAGE pljs AS $$ return null; $$;
SELECT ior_null() IS NULL AS null_ok;

DROP FUNCTION ior_i4_over, ior_i4_under, ior_i2_over, ior_i8_over, ior_big_i4,
  ior_big_i8, ior_big_i2, ior_nan, ior_inf, ior_ninf, ior_i2_min, ior_i2_max,
  ior_i4_min, ior_i4_max, ior_i8_min, ior_i8_max, ior_p53, ior_frac_pos,
  ior_frac_neg, ior_frac_edge, ior_null;
