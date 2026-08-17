-- Control for churn.sql: byte-for-byte the same DDL, with plpgsql bodies instead
-- of pljs ones.
--
-- The point is to separate two things that both show up as backend RSS growth:
--
--   * PostgreSQL's own cost for this DDL.  Each iteration replaces a function
--     (invalidating plancache and catcache entries) and rewrites a table twice via
--     ALTER COLUMN TYPE.  That bloats the catalogs and grows CacheMemoryContext,
--     and it does so for any PL, or none.
--   * pljs's cost, which is what the gate is actually about.
--
-- Run with MM_CHURN_CONTROL=1.  Whatever RSS delta this produces is the floor
-- below which the pljs number means nothing, so the two are compared rather than
-- the pljs number being read against a slack figure picked by hand.
SELECT nextval('pljs_mm_calls');

CREATE OR REPLACE FUNCTION mm_churn_ctl_fn() RETURNS int AS $$ BEGIN RETURN 1; END $$ LANGUAGE plpgsql;
SELECT mm_churn_ctl_fn();
CREATE OR REPLACE FUNCTION mm_churn_ctl_fn() RETURNS int AS $$ BEGIN RETURN 2; END $$ LANGUAGE plpgsql;
SELECT mm_churn_ctl_fn();

-- The plpgsql analogue of a body that fails in the validator.
DO $$ BEGIN
  EXECUTE 'CREATE OR REPLACE FUNCTION mm_churn_ctl_bad() RETURNS int AS $b$ this is ( not plpgsql $b$ LANGUAGE plpgsql';
  PERFORM mm_churn_ctl_bad();
EXCEPTION WHEN OTHERS THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE pljs_mm_churn ALTER COLUMN b TYPE varchar(64);
  ALTER TABLE pljs_mm_churn ALTER COLUMN b TYPE text;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT mm_assert_healthy();
