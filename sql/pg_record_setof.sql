-- Set-returning functions and record shaping (ported from plv8).
--
-- Pins the SETOF composite return_next path, the error when return_next gets a
-- non-object, and SETOF record with a caller-supplied column definition list
-- (both the matching and the column-count-mismatch cases). Error messages are
-- pinned as pljs emits them.
CREATE TYPE rec_t AS (a int, b text);

CREATE FUNCTION rs_ok() RETURNS SETOF rec_t LANGUAGE pljs AS $$
  pljs.return_next({ a: 1, b: 'x' });
  pljs.return_next({ a: 2, b: 'y' });
$$;
SELECT * FROM rs_ok() ORDER BY a;

CREATE FUNCTION rs_bad() RETURNS SETOF rec_t LANGUAGE pljs AS $$
  pljs.return_next(42);
$$;
SELECT * FROM rs_bad();

CREATE FUNCTION rs_record() RETURNS SETOF record LANGUAGE pljs AS $$
  pljs.return_next({ x: 1, y: 'a' });
  pljs.return_next({ x: 2, y: 'b' });
$$;
SELECT * FROM rs_record() AS t(x int, y text) ORDER BY x;
SELECT * FROM rs_record() AS t(x int, y text, z int);

DROP FUNCTION rs_ok();
DROP FUNCTION rs_bad();
DROP FUNCTION rs_record();
DROP TYPE rec_t;
