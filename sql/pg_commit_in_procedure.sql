-- Coverage, not a regression test: a non-atomic procedure that interleaves
-- pljs.execute() with pljs.commit() many times must run to completion.
--
-- This scenario arrived with a commit that reparented call_function()'s execution
-- context onto TopMemoryContext, on the theory that SPI_commit() could otherwise
-- free the context out from under a running function.  That commit was dropped
-- from this series: the hazard does not reproduce -- 50 iterations complete cleanly
-- on stock upstream and at every commit before the reparenting -- and the
-- reparenting itself introduced a leak of one memory context per failed call, since
-- a TopMemoryContext child is not reclaimed by transaction abort.
--
-- The scenario is still worth exercising, so it is kept here as coverage with its
-- provenance recorded, rather than deleted along with the fix it was attached to or
-- left in place implying it guards something.
--
-- pljs.commit() is also exercised by procedure.sql, pg_errordata_stack.sql and
-- pg_spi_freetuptable.sql, so this is additive rather than the only coverage.
CREATE EXTENSION IF NOT EXISTS pljs;

CREATE TABLE cip_t (a int);

CREATE PROCEDURE cip_loop(n int) LANGUAGE pljs AS $$
  let acc = 0;
  for (let i = 0; i < n; i++) {
    // Allocates in the execution context, then commits, then allocates again.
    const v = pljs.execute('SELECT $1::int AS v', [i])[0].v;
    acc += v;
    pljs.execute('INSERT INTO cip_t VALUES ($1)', [v]);
    pljs.commit();
  }
  pljs.elog(NOTICE, 'completed acc=' + acc);
$$;

CALL cip_loop(50);

SELECT count(*)::int AS rows_committed, sum(a)::int AS sum_committed FROM cip_t;

-- The rows are committed, so they survive a rollback of the enclosing block.
BEGIN;
DELETE FROM cip_t;
ROLLBACK;

SELECT count(*)::int AS rows_after_rollback FROM cip_t;

-- A caught error after all that commit traffic still leaves the session usable.
CREATE FUNCTION cip_after() RETURNS int LANGUAGE pljs AS $$
  try { pljs.execute('SELECT 1/0'); } catch (e) { /* expected */ }
  return pljs.execute('SELECT 7 AS v')[0].v;
$$;

SELECT cip_after() AS usable_after_commits;

DROP PROCEDURE cip_loop(int);
DROP FUNCTION cip_after();
DROP TABLE cip_t;
