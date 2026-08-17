-- Exhaustive-ish type-conversion matrix for the types the snowflake_cdc
-- procedures (and general pljs users) rely on.  Round-trips are compared inside
-- SQL wherever a rendered value would otherwise be locale/timezone dependent.
-- Deterministic float / timestamp rendering is pinned below.
--
-- This also pins two conversion fixes:
--   * an invalid JS Date (what 'infinity'::timestamptz reads back as) now binds
--     to SQL NULL instead of a bogus finite 2000-01-01;
--   * a multidimensional SQL array is rejected instead of being silently
--     flattened to one dimension.
-- ... and documents two inherent JS limitations (numeric precision is reduced
-- to float8; sub-millisecond timestamp precision is lost via JS Date).
CREATE EXTENSION IF NOT EXISTS pljs;
SET timezone = 'UTC';
SET datestyle = 'ISO, MDY';
SET extra_float_digits = 3;

-- ---------------------------------------------------------------- integers
CREATE FUNCTION id_i2(v int2) RETURNS int2 LANGUAGE pljs AS $$ return v; $$;
CREATE FUNCTION id_i4(v int4) RETURNS int4 LANGUAGE pljs AS $$ return v; $$;
CREATE FUNCTION id_i8(v int8) RETURNS int8 LANGUAGE pljs AS $$ return v; $$;
SELECT id_i2(32767::int2) AS i2max, id_i2((-32768)::int2) AS i2min;
SELECT id_i4(2147483647) AS i4max, id_i4(-2147483648) AS i4min;
-- int8 is a BigInt in JS: full 64-bit precision must survive (LSN use case).
SELECT id_i8(9223372036854775807) AS i8max, id_i8(-9223372036854775808) AS i8min;

-- ---------------------------------------------------------------- floats
CREATE FUNCTION id_f4(v float4) RETURNS float4 LANGUAGE pljs AS $$ return v; $$;
CREATE FUNCTION id_f8(v float8) RETURNS float8 LANGUAGE pljs AS $$ return v; $$;
SELECT id_f4(1.5) AS f4, id_f8(1.5) AS f8;
SELECT id_f8('NaN') AS nan, id_f8('Infinity') AS inf, id_f8('-Infinity') AS ninf, id_f8('-0') AS negzero;

-- ---------------------------------------------------------------- numeric
CREATE FUNCTION id_num(v numeric) RETURNS numeric LANGUAGE pljs AS $$ return v; $$;
-- A value representable in float8 round-trips exactly ...
SELECT id_num(12345.75) AS exact;
-- ... but numeric is marshalled through float8, so >15-16 significant digits are
-- lost (documented limitation, matches plv8).
SELECT (id_num('1234567890123456789'::numeric) = '1234567890123456789'::numeric) AS bigprec_exact;

-- ---------------------------------------------------------------- bool / text
CREATE FUNCTION id_bool(v bool) RETURNS bool LANGUAGE pljs AS $$ return v; $$;
SELECT id_bool(true) AS t, id_bool(false) AS f;
CREATE FUNCTION id_text(v text) RETURNS text LANGUAGE pljs AS $$ return v; $$;
SELECT id_text(U&'h\00e9llo\2603') AS unicode;

-- ---------------------------------------------------------------- uuid
CREATE FUNCTION id_uuid(v uuid) RETURNS uuid LANGUAGE pljs AS $$ return v; $$;
SELECT id_uuid('11111111-2222-3333-4444-555555555555') AS uuid_rt;

-- ---------------------------------------------------------------- bytea
CREATE FUNCTION bytea_str() RETURNS bytea LANGUAGE pljs AS $$ return "hello"; $$;
SELECT bytea_str() AS from_string;
CREATE FUNCTION bytea_u8() RETURNS bytea LANGUAGE pljs AS $$ return new Uint8Array([222, 173, 190, 239]); $$;
SELECT bytea_u8() AS from_uint8array;

-- ---------------------------------------------------------------- arrays
CREATE FUNCTION id_i4arr(v int4[]) RETURNS int4[] LANGUAGE pljs AS $$ return v; $$;
CREATE FUNCTION id_txtarr(v text[]) RETURNS text[] LANGUAGE pljs AS $$ return v; $$;
SELECT id_i4arr(ARRAY[1,2,3]) AS ints;
SELECT id_txtarr(ARRAY['a', NULL, 'c']) AS with_null;
SELECT id_i4arr(ARRAY[]::int4[]) AS empty;
-- Multidimensional arrays are rejected, not silently flattened.
SELECT id_i4arr(ARRAY[[1,2],[3,4]]) AS multidim;

-- ---------------------------------------------------------------- datetime
-- timestamptz round-trips (Date carries an absolute instant).
CREATE FUNCTION tstz_rt() RETURNS boolean LANGUAGE pljs AS $$
  var t = pljs.execute("SELECT '2024-03-15 12:34:56.789+00'::timestamptz AS t")[0].t;
  return pljs.execute(
    "SELECT ($1::timestamptz = '2024-03-15 12:34:56.789+00'::timestamptz) AS ok", [t])[0].ok;
$$;
SELECT tstz_rt();
-- date round-trips.
CREATE FUNCTION date_rt() RETURNS boolean LANGUAGE pljs AS $$
  var d = pljs.execute("SELECT '2024-03-15'::date AS d")[0].d;
  return pljs.execute("SELECT ($1::date = '2024-03-15'::date) AS ok", [d])[0].ok;
$$;
SELECT date_rt();
-- sub-millisecond precision is lost through JS Date (documented).
CREATE FUNCTION ts_subms_lost() RETURNS boolean LANGUAGE pljs AS $$
  var t = pljs.execute("SELECT '2024-03-15 12:34:56.789123+00'::timestamptz AS t")[0].t;
  return pljs.execute(
    "SELECT ($1::timestamptz = '2024-03-15 12:34:56.789123+00'::timestamptz) AS ok", [t])[0].ok;
$$;
SELECT ts_subms_lost() AS subms_preserved;
-- 'infinity' reads back as an invalid JS Date ...
CREATE FUNCTION inf_read() RETURNS text LANGUAGE pljs AS $$
  var t = pljs.execute("SELECT 'infinity'::timestamptz AS t")[0].t;
  return "isDate=" + (t instanceof Date) + " valid=" + !isNaN(t.getTime());
$$;
SELECT inf_read();
-- ... and binding that invalid Date back is SQL NULL, not a bogus 2000-01-01.
CREATE FUNCTION inf_write_null() RETURNS boolean LANGUAGE pljs AS $$
  var t = pljs.execute("SELECT 'infinity'::timestamptz AS t")[0].t;
  var r = pljs.execute("SELECT $1::timestamptz AS t", [t])[0].t;
  return r === null;
$$;
SELECT inf_write_null();

-- ---------------------------------------------------------------- jsonb
CREATE FUNCTION id_jb(v jsonb) RETURNS jsonb LANGUAGE pljs AS $$ return v; $$;
SELECT id_jb('{"a":[1,2,{"b":null,"c":true}],"d":"x","e":3.5}'::jsonb)
       = '{"a":[1,2,{"b":null,"c":true}],"d":"x","e":3.5}'::jsonb AS jb_deep_eq;

DROP FUNCTION id_i2, id_i4, id_i8, id_f4, id_f8, id_num, id_bool, id_text, id_uuid;
DROP FUNCTION bytea_str, bytea_u8, id_i4arr, id_txtarr;
DROP FUNCTION tstz_rt, date_rt, ts_subms_lost, inf_read, inf_write_null, id_jb;
RESET timezone;
RESET datestyle;
RESET extra_float_digits;

-- Multidimensional arrays: the two directions must agree.
--
-- Input already rejected a 2-D SQL array with a clear message.  Output did not
-- reject anything -- it silently produced numbers that looked like data.  The
-- conversion dispatched a JavaScript array to array-construction for *any*
-- non-json target, so the element loop converted each inner array to the element
-- type and returned the inner ArrayType pointer reinterpreted as int4:
--
--     RETURNS int[] with [[1,2],[3,4]]  ->  {357119344,357119392}
--
-- Both directions now raise.
CREATE FUNCTION tm_md_in(v int[]) RETURNS int LANGUAGE pljs AS $$ return 1; $$;
CREATE FUNCTION tm_md_out() RETURNS int[] LANGUAGE pljs AS $$ return [[1,2],[3,4]]; $$;

SELECT tm_md_in('{{1,2},{3,4}}'::int[]);
SELECT tm_md_out();

-- A JavaScript array aimed at a scalar is the same mistake, one dimension down.
CREATE FUNCTION tm_arr_scalar() RETURNS int LANGUAGE pljs AS $$ return [1,2]; $$;

SELECT tm_arr_scalar();

-- One-dimensional arrays are unaffected, in both directions.
SELECT tm_md_in('{1,2,3}'::int[]) AS flat_input_ok;

CREATE FUNCTION tm_flat_out() RETURNS int[] LANGUAGE pljs AS $$ return [1,2,3]; $$;

SELECT tm_flat_out() AS flat_output;

-- json and jsonb legitimately hold nested arrays and must keep working.
CREATE FUNCTION tm_jsonb_nested() RETURNS jsonb LANGUAGE pljs AS $$ return [[1,2],[3,4]]; $$;
CREATE FUNCTION tm_jsonb_arr() RETURNS jsonb[] LANGUAGE pljs AS $$ return [[1,2],[3]]; $$;

SELECT tm_jsonb_nested() AS jsonb_keeps_nesting;
SELECT tm_jsonb_arr() AS jsonb_array_of_arrays;

DROP FUNCTION tm_md_in(int[]);
DROP FUNCTION tm_md_out();
DROP FUNCTION tm_arr_scalar();
DROP FUNCTION tm_flat_out();
DROP FUNCTION tm_jsonb_nested();
DROP FUNCTION tm_jsonb_arr();

