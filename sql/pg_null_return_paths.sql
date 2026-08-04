-- SQL NULL returned through the composite, record and fallback paths.
--
-- pljs_jsvalue_to_datum() reports a NULL result to Postgres via
-- fcinfo->isnull, because the scalar return path in pljs_call_function()
-- discards the `is_null` out-parameter it passes.  Three paths bypassed that
-- and set only the out-parameter (or dereferenced a NULL one), so Postgres
-- received (Datum) 0 with isnull still false and read it as a real value:
--
--   1. A composite return type dispatched to pljs_jsvalue_to_record() *before*
--      the null/undefined check, so `return null` from a composite-returning
--      function handed Postgres a NULL pointer as a tuple -> backend SIGSEGV.
--   2. The RECORDOID path passed is_null = NULL, and the null branch of
--      pljs_jsvalue_to_record() dereferenced it unconditionally -> SIGSEGV.
--   3. pljs_jsvalue_to_datum_fallback() (every type with no explicit case:
--      uuid, inet, interval, time, money, domains, enums, extension types)
--      honoured an explicit `{is_null: true}` only through the out-parameter,
--      so a by-reference type dereferenced (Datum) 0 -> SIGSEGV, and a
--      by-value type such as `time` silently returned a bogus 00:00:00.
--
-- Each case below therefore doubles as a crash regression: the backend
-- surviving with the correct NULL *is* the signal.
CREATE EXTENSION IF NOT EXISTS pljs;

CREATE TYPE nrp_composite AS (a int, b text);
CREATE DOMAIN nrp_domain AS text;

-- 1) composite return type: null and undefined must be SQL NULL, not a crash.
CREATE FUNCTION nrp_ct_null() RETURNS nrp_composite LANGUAGE pljs AS $$ return null; $$;
CREATE FUNCTION nrp_ct_undef() RETURNS nrp_composite LANGUAGE pljs AS $$ return undefined; $$;
CREATE FUNCTION nrp_ct_value() RETURNS nrp_composite LANGUAGE pljs AS $$ return {a: 1, b: 'x'}; $$;
SELECT nrp_ct_null() IS NULL AS ct_null_is_sqlnull,
       nrp_ct_undef() IS NULL AS ct_undef_is_sqlnull;

-- a real composite value must still round-trip.
SELECT (nrp_ct_value()).a AS a, (nrp_ct_value()).b AS b;

-- the NULL composite must be usable in an expression (this dereferenced the
-- bogus tuple pointer before the fix).
SELECT COALESCE((nrp_ct_null()).a, -1) AS coalesced;

-- 2) RETURNS record: the code definition list path passes is_null = NULL.
CREATE FUNCTION nrp_rec_null() RETURNS record LANGUAGE pljs AS $$ return null; $$;
CREATE FUNCTION nrp_rec_undef() RETURNS record LANGUAGE pljs AS $$ return undefined; $$;
CREATE FUNCTION nrp_rec_value() RETURNS record LANGUAGE pljs AS $$ return {a: 7}; $$;
SELECT * FROM nrp_rec_null() AS t(a int);
SELECT * FROM nrp_rec_undef() AS t(a int);
SELECT * FROM nrp_rec_value() AS t(a int);

-- 3) fallback path: explicit {is_null: true} on types with no explicit case.
-- by-reference types (these dereferenced (Datum) 0 before the fix).
CREATE FUNCTION nrp_uuid() RETURNS uuid LANGUAGE pljs AS $$ return {is_null: true}; $$;
CREATE FUNCTION nrp_inet() RETURNS inet LANGUAGE pljs AS $$ return {is_null: true}; $$;
CREATE FUNCTION nrp_interval() RETURNS interval LANGUAGE pljs AS $$ return {is_null: true}; $$;
CREATE FUNCTION nrp_domain_fn() RETURNS nrp_domain LANGUAGE pljs AS $$ return {is_null: true}; $$;
SELECT nrp_uuid() IS NULL AS uuid_null,
       nrp_inet() IS NULL AS inet_null,
       nrp_interval() IS NULL AS interval_null,
       nrp_domain_fn() IS NULL AS domain_null;

-- materializing the value must not crash either.
SELECT nrp_uuid()::text AS uuid_text, nrp_interval()::text AS interval_text;

-- by-value fallback type: `time` silently returned 00:00:00 instead of NULL.
CREATE FUNCTION nrp_time() RETURNS time LANGUAGE pljs AS $$ return {is_null: true}; $$;
SELECT nrp_time() IS NULL AS time_null, nrp_time()::text AS time_text;

-- a real fallback value must still convert (the explicit-null check must not
-- swallow ordinary values).
CREATE FUNCTION nrp_uuid_value() RETURNS uuid LANGUAGE pljs AS $$
  return '11111111-2222-3333-4444-555555555555';
$$;
SELECT nrp_uuid_value() AS uuid_value, nrp_uuid_value() IS NULL AS is_null;

-- 4) the fcinfo-less bind path must keep reporting NULL through is_null: these
-- go through pljs_execute_params() with fcinfo = NULL, so the fix must not
-- start dereferencing it.
DO $$
  const u = pljs.execute('SELECT $1::uuid AS v', [null])[0].v;
  const t = pljs.execute('SELECT $1::text AS v', [null])[0].v;
  pljs.elog(NOTICE, 'bind null uuid/text -> ' + (u === null) + ' ' + (t === null));
$$ LANGUAGE pljs;

-- 5) an array return type must keep raising rather than silently becoming NULL
-- (the null check deliberately sits below the array checks).
CREATE FUNCTION nrp_arr_null() RETURNS int[] LANGUAGE pljs AS $$ return null; $$;
SELECT nrp_arr_null();

-- the backend is still alive and pljs still works after all of the above.
SELECT nrp_ct_value() IS NULL AS still_working;

DROP FUNCTION nrp_ct_null, nrp_ct_undef, nrp_ct_value, nrp_rec_null,
  nrp_rec_undef, nrp_rec_value, nrp_uuid, nrp_inet, nrp_interval,
  nrp_domain_fn, nrp_time, nrp_uuid_value, nrp_arr_null;
DROP DOMAIN nrp_domain;
DROP TYPE nrp_composite;
