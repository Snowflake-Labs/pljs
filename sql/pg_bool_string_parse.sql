-- A JavaScript string bound to bool is parsed, not coerced by truthiness.
--
-- JS_ToBool() reports every non-empty string as true, so "false", "f", "no" and
-- "0" all became true, while "" became false -- the exact opposite of what the
-- text says.  plv8 routed a bool through the type's input function, and this
-- difference is what silently broke snowflake_cdc's `needs_snapshot` flag on the
-- port: the flag was written as `needsSnapshot ? "true" : "false"`, so under
-- pljs it was set true and never cleared, and every subsequent change batch hit
-- the needs_snapshot skip and applied zero rows.
--
-- That was worked around SQL-side by comparing text instead -- `SET flag =
-- (? = 'true')` -- which keeps working and is still correct; it is simply no
-- longer load-bearing.
--
-- bool's input function accepts exactly what SQL accepts and raises on anything
-- else rather than guessing.
CREATE EXTENSION IF NOT EXISTS pljs;

-- 1) every spelling SQL accepts, in both directions, with the true/false split
-- landing where the text says it should.
DO $$
  const truthy = ['true', 't', 'TRUE', 'True', 'yes', 'y', 'on', '1', '  true  '];
  const falsy  = ['false', 'f', 'FALSE', 'False', 'no', 'n', 'off', '0', '  false  '];
  const bad = [];

  for (const s of truthy) {
    const v = pljs.execute('SELECT $1::bool AS v', [s])[0].v;
    if (v !== true) { bad.push(JSON.stringify(s) + ' -> ' + v); }
  }
  for (const s of falsy) {
    const v = pljs.execute('SELECT $1::bool AS v', [s])[0].v;
    if (v !== false) { bad.push(JSON.stringify(s) + ' -> ' + v); }
  }

  pljs.elog(NOTICE, 'all bool spellings correct: ' + (bad.length === 0) +
                    (bad.length ? ' failures: ' + bad.join(', ') : ''));
$$ LANGUAGE pljs;

-- 2) the exact shape that broke needs_snapshot: a JS boolean stringified and
-- bound must round-trip to itself.
DO $$
  for (const b of [true, false]) {
    const s = b ? 'true' : 'false';
    const v = pljs.execute('SELECT $1::bool AS v', [s])[0].v;
    pljs.elog(NOTICE, 'needs_snapshot ' + s + ' -> ' + v + ' correct=' + (v === b));
  }
$$ LANGUAGE pljs;

-- and the SQL-side workaround still yields the same answer.
DO $$
  for (const s of ['true', 'false']) {
    const v = pljs.execute('SELECT ($1 = $2) AS v', [s, 'true'])[0].v;
    pljs.elog(NOTICE, "idiom (? = 'true') " + s + ' -> ' + v);
  }
$$ LANGUAGE pljs;

-- 3) a bool return value, not just a bind.
CREATE FUNCTION bsp_false_str() RETURNS bool LANGUAGE pljs AS $$ return 'false'; $$;
CREATE FUNCTION bsp_true_str() RETURNS bool LANGUAGE pljs AS $$ return 'true'; $$;
CREATE FUNCTION bsp_f_str() RETURNS bool LANGUAGE pljs AS $$ return 'f'; $$;
SELECT bsp_false_str(), bsp_true_str(), bsp_f_str();

-- a bool column via return_next.
CREATE FUNCTION bsp_col() RETURNS TABLE(flag bool, k int) LANGUAGE pljs AS $$
  pljs.return_next({flag: 'false', k: 1});
  pljs.return_next({flag: 'true', k: 2});
$$;
SELECT k, flag FROM bsp_col() ORDER BY k;

-- 4) text that is not a boolean raises instead of silently becoming true, and
-- the empty string no longer masquerades as false.
CREATE FUNCTION bsp_bad() RETURNS bool LANGUAGE pljs AS $$ return 'maybe'; $$;
CREATE FUNCTION bsp_empty() RETURNS bool LANGUAGE pljs AS $$ return ''; $$;
SELECT bsp_bad();
SELECT bsp_empty();

-- 5) real JS booleans and truthiness of non-strings are unchanged.
CREATE FUNCTION bsp_true() RETURNS bool LANGUAGE pljs AS $$ return true; $$;
CREATE FUNCTION bsp_false() RETURNS bool LANGUAGE pljs AS $$ return false; $$;
CREATE FUNCTION bsp_zero() RETURNS bool LANGUAGE pljs AS $$ return 0; $$;
CREATE FUNCTION bsp_one() RETURNS bool LANGUAGE pljs AS $$ return 1; $$;
CREATE FUNCTION bsp_obj() RETURNS bool LANGUAGE pljs AS $$ return {}; $$;
SELECT bsp_true(), bsp_false(), bsp_zero(), bsp_one(), bsp_obj();

-- 6) NULL is still NULL.
CREATE FUNCTION bsp_null() RETURNS bool LANGUAGE pljs AS $$ return null; $$;
SELECT bsp_null() IS NULL AS null_ok;
DO $$
  pljs.elog(NOTICE, 'bind null bool -> ' +
    (pljs.execute('SELECT $1::bool AS v', [null])[0].v === null));
$$ LANGUAGE pljs;

DROP FUNCTION bsp_false_str, bsp_true_str, bsp_f_str, bsp_col, bsp_bad,
  bsp_empty, bsp_true, bsp_false, bsp_zero, bsp_one, bsp_obj, bsp_null;

-- An object-wrapped primitive is not JS_IsString(), so `new String("false")`
-- skipped the string branch and fell through to JS_ToBool(), which reports every
-- object as true -- reintroducing the exact inversion this case exists to
-- prevent.  String objects are now unwrapped and take the boolin path.
CREATE FUNCTION bsp_obj(v text) RETURNS bool LANGUAGE pljs AS $$ return new String(v); $$;

SELECT bsp_obj('false') AS obj_false, bsp_obj('f') AS obj_f, bsp_obj('no') AS obj_no,
       bsp_obj('0') AS obj_zero;
SELECT bsp_obj('true') AS obj_true, bsp_obj('yes') AS obj_yes, bsp_obj('on') AS obj_on;

-- ... and an unparseable one raises, exactly as the bare string does.
SELECT bsp_obj('maybe');

-- Only String objects are unwrapped.  A plain object keeps JavaScript's own
-- truthiness, which is at least the documented behaviour for it; unwrapping
-- everything would turn {} into the text "[object Object]" and raise from boolin.
CREATE FUNCTION bsp_plain() RETURNS bool LANGUAGE pljs AS $$ return {}; $$;
CREATE FUNCTION bsp_array() RETURNS bool LANGUAGE pljs AS $$ return []; $$;

SELECT bsp_plain() AS plain_object, bsp_array() AS empty_array;

DROP FUNCTION bsp_obj(text);
DROP FUNCTION bsp_plain();
DROP FUNCTION bsp_array();

