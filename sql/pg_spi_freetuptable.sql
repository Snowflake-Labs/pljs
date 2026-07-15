-- Regression test for the missing SPI_freetuptable() in pljs_execute.
--
-- pljs_plan_execute() freed its SPI tuptable after converting results, but
-- pljs_execute() (backing pljs.execute()) did not. After a pljs.commit() resets
-- SPI's internal state, the next pljs.execute() could reuse / free the stale
-- SPI_tuptable -- memory the commit already released -- and operate on a
-- dangling pointer, crashing the backend with SIGSEGV. This procedure runs
-- result-returning executes interleaved with commits many times; with the fix
-- it completes and every batch sees the full 50 rows.
CREATE TABLE t_freetup (a int);
CREATE PROCEDURE p_freetup() LANGUAGE pljs AS $$
  for (let i = 0; i < 20; i++) {
    const rows = pljs.execute('SELECT g FROM generate_series(1,50) g');
    pljs.execute('INSERT INTO t_freetup (a) VALUES ($1)', [rows.length]);
    pljs.commit();
  }
$$;
CALL p_freetup();
SELECT count(*)::int AS n, min(a) AS mn, max(a) AS mx FROM t_freetup;
DROP PROCEDURE p_freetup;
DROP TABLE t_freetup;
