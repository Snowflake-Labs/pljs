-- return_next() for a set with exactly one column.
--
-- A single-column set is not "composite", so pljs_return_next() converted the
-- argument directly as the column value.  That silently mangled the
-- `{column: value}` row object that a multi-column set requires: the whole
-- object went through the scalar conversion, so a text column stored
-- "[object Object]" and an int/bigint column stored 0 -- with no error at all.
--
-- Building a row object in a loop and calling return_next(row) is the natural
-- shape and the only one that works for 2+ columns, so a set-returning function
-- silently produced garbage as soon as it happened to have one column.
--
-- Both forms are accepted now.  The row-object reading applies only to a plain
-- object (a class brand check, so a Date, typed array or Array is still a
-- value), and only when the column type is not itself object-shaped -- a
-- json/jsonb or composite column legitimately takes an object.  An object that
-- identifies no value raises rather than storing garbage.
CREATE EXTENSION IF NOT EXISTS pljs;
CREATE TYPE snc_ct AS (a int, b text);

-- 1) the row-object form now works, and is exact for int8.
CREATE FUNCTION snc_text() RETURNS TABLE(nm text) LANGUAGE pljs AS $$
  pljs.return_next({nm: 'hello'});
$$;
CREATE FUNCTION snc_big() RETURNS TABLE(id bigint) LANGUAGE pljs AS $$
  pljs.return_next({id: 9007199254740993n});
  pljs.return_next({id: 9223372036854775807n});
$$;
CREATE FUNCTION snc_int() RETURNS TABLE(n int) LANGUAGE pljs AS $$
  pljs.return_next({n: 7});
$$;
SELECT nm FROM snc_text();
SELECT id FROM snc_big();
SELECT n FROM snc_int();

-- 2) the bare-value form keeps working.
CREATE FUNCTION snc_bare() RETURNS TABLE(nm text) LANGUAGE pljs AS $$
  pljs.return_next('bare');
  pljs.return_next(null);
$$;
SELECT coalesce(nm, 'NULL') AS nm FROM snc_bare();

-- 3) an explicit undefined for the column is SQL NULL, not an error.
CREATE FUNCTION snc_undef() RETURNS TABLE(nm text) LANGUAGE pljs AS $$
  pljs.return_next({nm: undefined});
$$;
SELECT coalesce(nm, 'NULL') AS nm FROM snc_undef();

-- 4) an object that does not identify a single value raises instead of storing
-- "[object Object]" / 0.
CREATE FUNCTION snc_ambig() RETURNS TABLE(nm text) LANGUAGE pljs AS $$
  pljs.return_next({a: 1, b: 2});
$$;
SELECT nm FROM snc_ambig();
CREATE FUNCTION snc_empty() RETURNS TABLE(nm text) LANGUAGE pljs AS $$
  pljs.return_next({});
$$;
SELECT nm FROM snc_empty();

-- 5) object-shaped column types must still take the object as the value.
CREATE FUNCTION snc_jsonb() RETURNS TABLE(j jsonb) LANGUAGE pljs AS $$
  pljs.return_next({a: 1, b: 2});
$$;
SELECT j FROM snc_jsonb();
CREATE FUNCTION snc_comp() RETURNS TABLE(c snc_ct) LANGUAGE pljs AS $$
  pljs.return_next({a: 1, b: 'q'});
$$;
SELECT * FROM snc_comp();
CREATE FUNCTION snc_setof() RETURNS SETOF snc_ct LANGUAGE pljs AS $$
  pljs.return_next({a: 3, b: 'r'});
$$;
SELECT a, b FROM snc_setof();

-- 6) branded object-like values are values, not row objects.
CREATE FUNCTION snc_date() RETURNS TABLE(ts timestamptz) LANGUAGE pljs AS $$
  pljs.return_next(new Date(Date.UTC(2020, 0, 2, 3, 4, 5)));
$$;
CREATE FUNCTION snc_bytea() RETURNS TABLE(b bytea) LANGUAGE pljs AS $$
  pljs.return_next(new Uint8Array([1, 2, 3]));
$$;
CREATE FUNCTION snc_arr() RETURNS TABLE(a int[]) LANGUAGE pljs AS $$
  pljs.return_next([1, 2, 3]);
$$;
SET TIME ZONE 'UTC';
SELECT ts FROM snc_date();
SELECT encode(b, 'hex') AS b_hex FROM snc_bytea();
SELECT a FROM snc_arr();

-- 7) multi-column sets are unchanged, including the strict key check.
CREATE FUNCTION snc_two() RETURNS TABLE(a int, b text) LANGUAGE pljs AS $$
  pljs.return_next({a: 5, b: 'm'});
  pljs.return_next({a: 6, b: null});
$$;
SELECT a, coalesce(b, 'NULL') AS b FROM snc_two();
CREATE FUNCTION snc_two_missing() RETURNS TABLE(a int, b text) LANGUAGE pljs AS $$
  pljs.return_next({a: 1});
$$;
SELECT a FROM snc_two_missing();

RESET TIME ZONE;
DROP FUNCTION snc_text, snc_big, snc_int, snc_bare, snc_undef, snc_ambig,
  snc_empty, snc_jsonb, snc_comp, snc_setof, snc_date, snc_bytea, snc_arr,
  snc_two, snc_two_missing;
DROP TYPE snc_ct;
