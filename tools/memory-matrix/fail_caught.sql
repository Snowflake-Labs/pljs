-- Failures CAUGHT inside JavaScript, so the enclosing call succeeds.  This is
-- the class the pre-existing tools/pljs-soak.sh already covered; it is kept
-- here because it exercises a different mechanism (the errordata stack and the
-- SPI connection's reusability) from fail_escape.sql.
SELECT nextval('pljs_mm_calls');

-- 12 caught errors in ONE call.  Without FlushErrorState() in every PG_CATCH the
-- sixth PANICs the cluster with "ERRORDATA_STACK_SIZE exceeded", which is a
-- cluster-wide outage rather than a session error.  Returns the count so a
-- silently-swallowed error shows up as a wrong number.
SELECT mmc_many_caught(4);

-- Three nested execute levels, failing innermost, caught outermost with the
-- message and SQLSTATE intact.
SELECT mmc_nested();

-- A caught error must roll back its own write and nothing else.
SELECT mmc_subxact();

SELECT mm_assert_healthy();
