-- A window function's polymorphic argument type was never resolved.
--
-- convert_arguments_to_javascript() resolves `anyelement` via
-- get_fn_expr_argtype() in its ordinary-function branch but not in its window
-- branch, and the window helpers (get_func_arg_in_partition / _in_frame /
-- _current) read `storage->function->argtypes[]`, which is per-OID *cached*
-- state filled in by whichever call compiled the function first.
--
-- Both defects were masked by the old byte-level conversion fallback, which
-- reinterpreted the datum as an int32: that happened to be right for int4 and
-- wrong for everything else, and the value round-tripped only because the same
-- wrong encoding was used on the way back out.  Anything JavaScript actually did
-- with the value saw garbage.
--
-- The caching defect also made the result order-dependent inside one session:
-- calling the same window function with int4 and then with date converted the
-- date datum as an int4, so the second query returned a raw day count.
SET timezone = 'UTC';
SET datestyle = 'ISO, MDY';
CREATE EXTENSION IF NOT EXISTS pljs;

CREATE TABLE poly_win (id int, d date, t text, ts timestamptz, sal int);
INSERT INTO poly_win VALUES
  (1, '2007-12-10', 'alpha', '2007-12-10 10:00+00', 100),
  (2, '2006-12-23', 'bravo', '2006-12-23 11:00+00', 200),
  (3, '2008-01-01', 'charlie', '2008-01-01 12:00+00', 300);

-- Returns the previous row's argument, converted to a string *in JavaScript*.
-- This is what exposes the argument's real JS type; a function that just hands
-- the value straight back can hide a wrong encoding.
CREATE FUNCTION poly_lag_str(arg anyelement) RETURNS text AS $$
  var w = pljs.get_window_object();
  var v = w.get_func_arg_in_partition(0, -1, w.SEEK_CURRENT, false);

  if (v === undefined) { return 'undefined'; }
  return (v instanceof Date ? 'Date:' + v.toISOString() : typeof v + ':' + String(v));
$$ LANGUAGE pljs WINDOW;

-- Each type must be seen as itself, whatever order the calls happen in.
SELECT id, poly_lag_str(id) OVER (ORDER BY sal) AS int_arg FROM poly_win ORDER BY sal;
SELECT d, poly_lag_str(d) OVER (ORDER BY sal) AS date_arg FROM poly_win ORDER BY sal;
SELECT t, poly_lag_str(t) OVER (ORDER BY sal) AS text_arg FROM poly_win ORDER BY sal;
SELECT ts, poly_lag_str(ts) OVER (ORDER BY sal) AS ts_arg FROM poly_win ORDER BY sal;

-- Repeat the int4 call last: a cached resolution would now poison it.
SELECT id, poly_lag_str(id) OVER (ORDER BY sal) AS int_arg_again FROM poly_win ORDER BY sal;

-- Now the reverse order in a single session, which is the ordering that used to
-- return day counts (2900, 2548) for date_after_int.
CREATE FUNCTION poly_lag(arg anyelement) RETURNS anyelement AS $$
  var w = pljs.get_window_object();
  return w.get_func_arg_in_partition(0, -1, w.SEEK_CURRENT, false);
$$ LANGUAGE pljs WINDOW;

SELECT id, poly_lag(id) OVER (ORDER BY sal) AS int_first FROM poly_win ORDER BY sal;
SELECT d, poly_lag(d) OVER (ORDER BY sal) AS date_after_int FROM poly_win ORDER BY sal;
SELECT t, poly_lag(t) OVER (ORDER BY sal) AS text_after_date FROM poly_win ORDER BY sal;

-- get_func_arg_current() and get_func_arg_in_frame() take the same path.
CREATE FUNCTION poly_current_str(arg anyelement) RETURNS text AS $$
  var w = pljs.get_window_object();
  var v = w.get_func_arg_current(0);

  return (v instanceof Date ? 'Date:' + v.toISOString() : typeof v + ':' + String(v));
$$ LANGUAGE pljs WINDOW;

SELECT d, poly_current_str(d) OVER (ORDER BY sal) AS current_date_arg FROM poly_win ORDER BY sal;

CREATE FUNCTION poly_frame_str(arg anyelement) RETURNS text AS $$
  var w = pljs.get_window_object();
  var v = w.get_func_arg_in_frame(0, 0, w.SEEK_HEAD, false);

  if (v === undefined) { return 'undefined'; }
  return (v instanceof Date ? 'Date:' + v.toISOString() : typeof v + ':' + String(v));
$$ LANGUAGE pljs WINDOW;

SELECT d, poly_frame_str(d) OVER (ORDER BY sal ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
         AS frame_date_arg
FROM poly_win ORDER BY sal;

-- A non-polymorphic window argument is unaffected.
CREATE FUNCTION mono_lag_str(arg date) RETURNS text AS $$
  var w = pljs.get_window_object();
  var v = w.get_func_arg_in_partition(0, -1, w.SEEK_CURRENT, false);

  if (v === undefined) { return 'undefined'; }
  return (v instanceof Date ? 'Date:' + v.toISOString() : typeof v);
$$ LANGUAGE pljs WINDOW;

SELECT d, mono_lag_str(d) OVER (ORDER BY sal) AS mono_date_arg FROM poly_win ORDER BY sal;

DROP FUNCTION poly_lag_str(anyelement);
DROP FUNCTION poly_lag(anyelement);
DROP FUNCTION poly_current_str(anyelement);
DROP FUNCTION poly_frame_str(anyelement);
DROP FUNCTION mono_lag_str(date);
DROP TABLE poly_win;
RESET timezone;
RESET datestyle;
