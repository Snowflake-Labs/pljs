-- Regression: a PostgreSQL error raised inside pljs.return_next() crashed the
-- backend later, from an unrelated statement.
--
-- return_next is a C function that QuickJS called, so QuickJS has live
-- JSStackFrame structures on the C stack between it and the interpreter, linked
-- from the runtime.  An ereport(ERROR) there siglongjmps straight past them and
-- leaves rt->current_stack_frame pointing at frames that no longer exist.
--
-- Nothing appears wrong at that point.  The damage shows up the next time
-- anything walks that frame list, which is what constructing an Error does via
-- build_backtrace() -- so a later, entirely unrelated `throw new Error(...)`
-- segfaults the backend:
--
--     build_backtrace <- js_error_constructor <- JS_Call <- call_trigger
--
-- Two statements reproduce it: one failing SETOF call, then any trigger.
--
-- This was latent until the conversion paths began rejecting bad values instead
-- of silently mangling them: an out-of-range integer used to wrap, so
-- return_next never raised.  Bisected to the commit that added the integer range
-- check, which did not introduce the defect so much as make it reachable.
--
-- pljs.execute() has always converted PostgreSQL errors into JavaScript
-- exceptions for exactly this reason; return_next now does the same.
CREATE TYPE rnx_row AS (a int);

-- Raises from inside return_next: 2^31 does not fit in int4.
CREATE FUNCTION rnx_bad_srf() RETURNS SETOF rnx_row AS $$
  pljs.return_next({ a: 2147483648 });
$$ LANGUAGE pljs;

CREATE TABLE rnx_t (x int);

CREATE FUNCTION rnx_trigger() RETURNS trigger AS $$
  throw new Error('trigger error');
$$ LANGUAGE pljs;

CREATE TRIGGER rnx_tr BEFORE INSERT ON rnx_t
  FOR EACH ROW EXECUTE FUNCTION rnx_trigger();

-- 1) The failing SETOF call reports the conversion error, catchably.
DO $$ BEGIN
  PERFORM count(*) FROM rnx_bad_srf();
  RAISE EXCEPTION 'expected the conversion to fail';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'srf failed as expected: %', SQLERRM;
END $$;

-- 2) A trigger that constructs an Error afterwards: this is what crashed.
DO $$ BEGIN
  INSERT INTO rnx_t VALUES (1);
  RAISE EXCEPTION 'expected the trigger to fail';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'trigger failed as expected: %', SQLERRM;
END $$;

-- 3) And the session is still fully usable in both directions.
DO $$ BEGIN
  PERFORM count(*) FROM rnx_bad_srf();
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT 'session still usable' AS status;

-- Interleave the two paths many times: the frame list must stay coherent.
CREATE FUNCTION rnx_interleave(n int) RETURNS int AS $$
DECLARE i int; ok int := 0;
BEGIN
  FOR i IN 1..n LOOP
    BEGIN PERFORM count(*) FROM rnx_bad_srf(); EXCEPTION WHEN OTHERS THEN ok := ok + 1; END;
    BEGIN INSERT INTO rnx_t VALUES (1);        EXCEPTION WHEN OTHERS THEN ok := ok + 1; END;
  END LOOP;
  RETURN ok;
END $$ LANGUAGE plpgsql;

SELECT rnx_interleave(100) AS failures_handled_without_crashing;

-- A successful SETOF call must still work after all of that.
CREATE FUNCTION rnx_good_srf() RETURNS SETOF rnx_row AS $$
  for (let i = 0; i < 3; i++) pljs.return_next({ a: i });
$$ LANGUAGE pljs;

SELECT count(*) AS good_rows FROM rnx_good_srf();

DROP TRIGGER rnx_tr ON rnx_t;
DROP FUNCTION rnx_interleave, rnx_bad_srf, rnx_good_srf, rnx_trigger;
DROP TABLE rnx_t;
DROP TYPE rnx_row;
