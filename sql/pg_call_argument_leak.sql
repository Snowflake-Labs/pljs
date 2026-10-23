-- Regression: a call must free the JavaScript values it made for its arguments.
--
-- convert_arguments_to_javascript() turns each argument into a JS value, and
-- JS_Call() only borrows them, so they stay alive until the caller frees them.
-- Nothing did: every string, object or other non-constant argument was kept by
-- the runtime for the rest of the session, a few dozen bytes per call that no
-- garbage collection reclaims.  A backend that keeps calling, such as a
-- background worker that calls the same procedure every second, grows without
-- bound until it reaches pljs.memory_limit.
--
-- Each case below makes 1000 calls and compares the runtime's allocation count
-- after a full collection.  Before the fix every case retained at least 1000
-- allocations; the bound below only allows for the runtime's own bookkeeping.
CREATE EXTENSION IF NOT EXISTS pljs;

CREATE FUNCTION arg_leak_gc() RETURNS int LANGUAGE pljs AS $$
  pljs.gc();
  return 1;
$$;
CREATE FUNCTION arg_leak_count() RETURNS bigint LANGUAGE sql AS $$
  SELECT arg_leak_gc();
  SELECT (pljs_info() ->> 'malloc_count')::bigint;
$$;
CREATE TABLE arg_leak_counts (label text PRIMARY KEY, before bigint);

CREATE FUNCTION arg_leak_text(t text) RETURNS int LANGUAGE pljs AS $$
  return t.length;
$$;
CREATE FUNCTION arg_leak_jsonb(j jsonb) RETURNS int LANGUAGE pljs AS $$
  return j.a.length;
$$;
CREATE FUNCTION arg_leak_throw(t text) RETURNS int LANGUAGE pljs AS $$
  throw new Error('thrown for ' + t);
$$;
CREATE PROCEDURE arg_leak_inout(INOUT r text) LANGUAGE pljs AS $$
  return r + '!';
$$;

-- Warm every function up once, so that compiling and caching it is not counted.
SELECT arg_leak_text('warm'), arg_leak_jsonb('{"a": [1]}');
CALL arg_leak_inout('warm');
DO $$ BEGIN PERFORM arg_leak_throw('warm'); EXCEPTION WHEN OTHERS THEN NULL; END $$;
SELECT arg_leak_count() IS NOT NULL AS warmed;

-- 1) A text argument, the second and later calls going through the function
-- cache.
INSERT INTO arg_leak_counts VALUES ('text', arg_leak_count());
SELECT sum(arg_leak_text('call ' || g)) > 0 AS text_ok
  FROM generate_series(1, 1000) g;
SELECT arg_leak_count() - before < 50 AS text_args_freed
  FROM arg_leak_counts WHERE label = 'text';

-- 2) A jsonb argument, which becomes an object with an array in it.
INSERT INTO arg_leak_counts VALUES ('jsonb', arg_leak_count());
SELECT sum(arg_leak_jsonb(jsonb_build_object('a', jsonb_build_array(g, g)))) = 2000
  AS jsonb_ok
  FROM generate_series(1, 1000) g;
SELECT arg_leak_count() - before < 50 AS jsonb_args_freed
  FROM arg_leak_counts WHERE label = 'jsonb';

-- 3) A call that throws: its arguments are freed on the way out too.
INSERT INTO arg_leak_counts VALUES ('throw', arg_leak_count());
DO $$
BEGIN
  FOR i IN 1..1000 LOOP
    BEGIN
      PERFORM arg_leak_throw('call ' || i);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END
$$;
SELECT arg_leak_count() - before < 50 AS thrown_args_freed
  FROM arg_leak_counts WHERE label = 'throw';

-- 4) A procedure's INOUT argument.
INSERT INTO arg_leak_counts VALUES ('inout', arg_leak_count());
DO $$
DECLARE r text;
BEGIN
  FOR i IN 1..1000 LOOP
    r := 'call ' || i;
    CALL arg_leak_inout(r);
  END LOOP;
END
$$;
SELECT arg_leak_count() - before < 50 AS inout_args_freed
  FROM arg_leak_counts WHERE label = 'inout';

DROP TABLE arg_leak_counts;
DROP PROCEDURE arg_leak_inout(text);
DROP FUNCTION arg_leak_throw(text);
DROP FUNCTION arg_leak_jsonb(jsonb);
DROP FUNCTION arg_leak_text(text);
DROP FUNCTION arg_leak_count();
DROP FUNCTION arg_leak_gc();
