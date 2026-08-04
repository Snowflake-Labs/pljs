-- Differential port of plv8's regression scenarios to pljs.
--
-- Source (PostgreSQL License, same as pljs): plv8's sql/scalar_args.sql,
-- sql/varparam.sql and sql/bytea.sql. QuickJS (pljs) matches V8 (plv8) on these
-- cases except for two behaviours called out below and recorded in
-- pljs-patches/PROVENANCE.md: prepare() parameter-type deduction and the bytea
-- *result* representation. Function names are prefixed pp_ to avoid clashing
-- with pljs's own bytea regression test. This guards the plv8-compatible surface
-- the snowflake_cdc procedures depend on.

-- scalar_args: jsonb scalars and containers round-trip through a pljs argument
-- (matches plv8 byte for byte).
CREATE FUNCTION pp_jsonb_scalar_cat(data jsonb) RETURNS jsonb LANGUAGE pljs AS
$$ pljs.elog(NOTICE, 'arg = ' + JSON.stringify(data)); return data; $$;
SELECT pp_jsonb_scalar_cat(to_jsonb('asd'::TEXT));
SELECT pp_jsonb_scalar_cat(to_jsonb(19450509::INT));
SELECT pp_jsonb_scalar_cat(to_jsonb(false::BOOL));
SELECT pp_jsonb_scalar_cat('{"key":[null, true, false, 19450509, "string"]}'::JSONB);
SELECT pp_jsonb_scalar_cat('{"key":null}'::JSONB);
DROP FUNCTION pp_jsonb_scalar_cat(jsonb);

-- varparam: prepare()/execute()/cursor() and variadic execute arguments (bare
-- value, one-element array, and multiple bare values) match plv8.
-- DIVERGENCE (see PROVENANCE.md): plv8 deduces prepared-statement parameter
-- types from the query; pljs requires them to be given to prepare(), so this
-- passes the explicit type list ["oid"] that plv8's varparam.sql omits.
DO LANGUAGE pljs $$
  var plan = pljs.prepare("SELECT relname FROM pg_class WHERE oid = $1", ["oid"]);
  pljs.elog(INFO, plan.execute(["1259"]).shift().relname);
  var cur = plan.cursor(["2610"]);
  pljs.elog(INFO, cur.fetch().relname);
  cur.close();
  plan.free();
$$;
DO LANGUAGE pljs $$
  pljs.elog(INFO, JSON.stringify(pljs.execute("SELECT $1", 1)));
  pljs.elog(INFO, JSON.stringify(pljs.execute("SELECT $1", [1])));
  pljs.elog(INFO, JSON.stringify(pljs.execute("SELECT $1 a, $2 b", 1, 2)));
$$;

-- bytea (return path): a typed array / ArrayBuffer returned from a pljs function
-- becomes a bytea of the corresponding byte length -- matches plv8.
CREATE FUNCTION pp_arraybuffer_bytea(len integer) RETURNS bytea LANGUAGE pljs IMMUTABLE STRICT AS $$ return new ArrayBuffer(len); $$;
SELECT length(pp_arraybuffer_bytea(20));
CREATE FUNCTION pp_int16array_bytea(len integer) RETURNS bytea LANGUAGE pljs IMMUTABLE STRICT AS $$ return new Int16Array(len); $$;
SELECT length(pp_int16array_bytea(20));
DROP FUNCTION pp_arraybuffer_bytea(integer);
DROP FUNCTION pp_int16array_bytea(integer);

-- bytea (result path): a bytea result column is a Uint8Array, matching plv8, so
-- plv8's own idiom -- String.fromCharCode.apply(null, bytea) -- works here too.
-- This used to be a divergence: pljs surfaced a JS string, which threw on that
-- idiom and, worse, silently destroyed any byte that was not valid UTF-8 (see
-- sql/pg_bytea_bytes.sql).  Both engines now agree.
DO LANGUAGE pljs $$
  const b = pljs.execute("select 'abc'::bytea AS x")[0].x;
  pljs.elog(NOTICE, 'bytea result typeof=' + (typeof b) + ' value=' + b);
  pljs.elog(NOTICE, 'plv8 idiom works: ' +
                    (String.fromCharCode.apply(null, b) === 'abc'));
$$;
