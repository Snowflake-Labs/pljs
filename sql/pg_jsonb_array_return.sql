-- Regression: `RETURNS jsonb[]` (and json[]) could not return anything at all.
--
-- pljs_type_fill() rewrites pljs_type.typid to the ELEMENT type for an array,
-- so the "is this a bare json/jsonb target?" guard in pljs_jsvalue_to_datum()
-- --  type.typid != JSONOID && type.typid != JSONBOID -- also matched jsonb[]
-- and json[], whose element type IS json/jsonb.  Those never reached
-- pljs_jsvalue_to_array(); they fell through to the scalar json branch, which
-- stringified the whole JavaScript array and handed it to the json input
-- function:
--
--   ERROR:  invalid input syntax for type json
--   DETAIL:  Token "object" is invalid.
--   CONTEXT:  JSON data, line 1: [object...
--
-- On stock upstream the same path read uninitialised memory as a type OID and
-- reported "cache lookup failed for type 2139062143" -- 0x7F7F7F7F, the
-- wiped-memory pattern -- so this was never a working return type.
--
-- The dispatch now keys off the SQL type's category, which pljs_type_fill()
-- leaves pointing at the original type.
CREATE FUNCTION jba_objects() RETURNS jsonb[] AS $$
  return [{ a: 1 }, { b: 2 }];
$$ LANGUAGE pljs;

CREATE FUNCTION jba_scalars() RETURNS jsonb[] AS $$
  return [1, 2, 3];
$$ LANGUAGE pljs;

CREATE FUNCTION jba_strings() RETURNS jsonb[] AS $$
  return ['{"a":1}', 'x'];
$$ LANGUAGE pljs;

-- A nested JavaScript array becomes a JSON array *element*, not a second SQL
-- dimension: the element type is jsonb, which can hold an array itself.
CREATE FUNCTION jba_nested() RETURNS jsonb[] AS $$
  return [[1, 2], [3]];
$$ LANGUAGE pljs;

-- null and undefined stay SQL NULL in place, without collapsing the array.
CREATE FUNCTION jba_nulls() RETURNS jsonb[] AS $$
  return [{ a: 1 }, null, undefined, { b: 2 }];
$$ LANGUAGE pljs;

CREATE FUNCTION jba_json() RETURNS json[] AS $$
  return [{ a: 1 }, [2]];
$$ LANGUAGE pljs;

-- The guard's original purpose must survive: a bare jsonb target still turns a
-- JavaScript array into a JSON array rather than a SQL array.
CREATE FUNCTION jba_bare_object() RETURNS jsonb AS $$
  return { a: 1 };
$$ LANGUAGE pljs;

CREATE FUNCTION jba_bare_array() RETURNS jsonb AS $$
  return [1, { b: 2 }];
$$ LANGUAGE pljs;

SELECT jba_objects();
SELECT array_length(jba_objects(), 1) AS len, (jba_objects())[1] -> 'a' AS first_a;
SELECT jba_scalars();
SELECT jba_strings();
SELECT jba_nested();
SELECT jba_nulls();
SELECT array_length(jba_nulls(), 1) AS len,
       (jba_nulls())[2] IS NULL AS second_is_null,
       (jba_nulls())[3] IS NULL AS third_is_null;
SELECT jba_json();
SELECT jba_bare_object();
SELECT jba_bare_array();

-- The same path is used for bind parameters, not just return values.
DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n FROM unnest(jba_objects()) AS u;
  IF n <> 2 THEN
    RAISE EXCEPTION 'expected 2 elements, got %', n;
  END IF;
END $$;

CREATE FUNCTION jba_roundtrip() RETURNS jsonb AS $$
  const rows = pljs.execute('SELECT $1::jsonb[] AS a', [[{ x: 1 }, { y: 2 }]]);
  return { got: rows[0].a };
$$ LANGUAGE pljs;

SELECT jba_roundtrip();

DROP FUNCTION jba_objects, jba_scalars, jba_strings, jba_nested, jba_nulls,
              jba_json, jba_bare_object, jba_bare_array, jba_roundtrip;
