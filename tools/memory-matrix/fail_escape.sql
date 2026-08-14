-- Failures that ESCAPE call_function, each caught at the SQL level so pgbench
-- does not abort the client, and each followed by mm_assert_healthy() so that a
-- backend left in a bad state by the failure shows up as a WRONG ANSWER rather
-- than only as memory growth.
--
-- The assertion is in this same file on purpose: pgbench weighting cannot
-- guarantee that a success script follows a failure script, but a statement
-- later in the same script always does.
SELECT nextval('pljs_mm_calls');

DO $$ BEGIN PERFORM mmf_overflow_int4();   EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_overflow_int8();   EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_nan();             EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_infinity();        EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_bad_string();      EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_bytea_number();    EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_throw();           EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_self_reference();  EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM mmf_deep_recursion();  EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM count(*) FROM mmf_column_mismatch();
           EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- Recovery: everything above failed; the backend must still be fully correct.
SELECT mm_assert_healthy();
