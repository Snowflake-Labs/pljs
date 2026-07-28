-- Cache-invalidation regression.
--
-- pljs caches compiled functions per pg_proc OID and runs queries via SPI.
-- DDL, function redefinition and DISCARD between calls must never return stale
-- results or crash the backend.
CREATE EXTENSION IF NOT EXISTS pljs;

-- CREATE OR REPLACE must invalidate the cached compiled function body.
CREATE FUNCTION ver() RETURNS int LANGUAGE pljs AS $$ return 1; $$;
SELECT ver() AS v1;
CREATE OR REPLACE FUNCTION ver() RETURNS int LANGUAGE pljs AS $$ return 2; $$;
SELECT ver() AS v2;

-- DDL on a table read from inside a pljs function is picked up on the next call.
CREATE TABLE cinv(a int);
INSERT INTO cinv VALUES (10);
CREATE FUNCTION read_cinv() RETURNS int LANGUAGE pljs AS $$
  return pljs.execute("SELECT sum(a)::int AS s FROM cinv")[0].s;
$$;
SELECT read_cinv() AS before_ddl;
ALTER TABLE cinv ADD COLUMN b int;
INSERT INTO cinv VALUES (5, 1);
SELECT read_cinv() AS after_add_column;

-- Dropping a column the cached query references produces a clean, catchable
-- error (re-planned against the new catalog), not a crash or stale result.
ALTER TABLE cinv DROP COLUMN a;
CREATE FUNCTION read_cinv_safe() RETURNS text LANGUAGE pljs AS $$
  try { return "ok:" + pljs.execute("SELECT sum(a)::int AS s FROM cinv")[0].s; }
  catch (e) { return "err"; }
$$;
SELECT read_cinv_safe() AS after_drop_column;

-- DISCARD ALL between calls must leave pljs usable.
DISCARD ALL;
CREATE FUNCTION after_discard() RETURNS int LANGUAGE pljs AS $$ return 42; $$;
SELECT after_discard() AS after_discard;
SELECT 1 AS alive;

DROP TABLE cinv;
DROP FUNCTION ver();
DROP FUNCTION read_cinv();
DROP FUNCTION read_cinv_safe();
DROP FUNCTION after_discard();
