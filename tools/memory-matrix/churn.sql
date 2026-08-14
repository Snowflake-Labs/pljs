-- Cache churn: invalidate the pljs function cache and the type cache while the
-- backend is hot.  A function replaced under a live cache, or a column whose
-- type changes, is what the cache-invalidation and window-polymorphic fixes are
-- about; doing it mid-soak also checks that the invalidation path itself does
-- not leak.
SELECT nextval('pljs_mm_calls');

-- Replace a function body in place, then call it.
CREATE OR REPLACE FUNCTION mm_churn_fn() RETURNS int AS $$ return 1; $$ LANGUAGE pljs;
SELECT mm_churn_fn();
CREATE OR REPLACE FUNCTION mm_churn_fn() RETURNS int AS $$ return 2; $$ LANGUAGE pljs;
SELECT mm_churn_fn();

-- A compile-time JavaScript syntax error: fails in the validator, not at call
-- time, and must not leave anything behind.
DO $$ BEGIN
  EXECUTE 'CREATE OR REPLACE FUNCTION mm_churn_bad() RETURNS int AS $b$ this is ( not js $b$ LANGUAGE pljs';
  PERFORM mm_churn_bad();
EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- Alter a column type under a cached plan.
DO $$ BEGIN
  ALTER TABLE pljs_mm_churn ALTER COLUMN b TYPE varchar(64);
  ALTER TABLE pljs_mm_churn ALTER COLUMN b TYPE text;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT mm_assert_healthy();
