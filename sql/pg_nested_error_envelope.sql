-- Stressor distilled from snowflake_cdc: nested-error propagation across the SPI
-- boundary (extends the 0010 fix beyond a single hop).
--
-- The mirror procedures run SQL through pljs.execute that can itself raise, and
-- rely on the full error envelope -- message, SQLSTATE, DETAIL, HINT -- to make
-- decisions and to log actionable errors. This checks that a plpgsql RAISE with
-- an explicit ERRCODE/DETAIL/HINT surfaces intact on the caught JS exception,
-- and that a plain division-by-zero keeps its message rather than collapsing to
-- a generic "execution error".
DO $$
  try {
    pljs.execute("DO $inner$ BEGIN RAISE EXCEPTION 'boom detail' USING ERRCODE='22012', DETAIL='dd', HINT='hh'; END $inner$ LANGUAGE plpgsql");
    pljs.elog(NOTICE, 'no error raised (unexpected)');
  } catch (e) {
    pljs.elog(NOTICE, 'msg_has_boom=' + /boom detail/.test(e.message) +
                      ' sqlstate=' + e.sqlerrcode + ' detail=' + e.detail + ' hint=' + e.hint);
  }
  try {
    pljs.execute('SELECT 1/0');
    pljs.elog(NOTICE, 'no error raised (unexpected)');
  } catch (e) {
    pljs.elog(NOTICE, 'div0 msg_has_zero=' + /division by zero/.test(e.message));
  }
$$ LANGUAGE pljs;
