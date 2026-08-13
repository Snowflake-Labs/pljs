-- Regression test for the unpopulated nulls[] array in pljs_execute_params.
--
-- The nulls[] array was palloc'd but never written: pljs_jsvalue_to_datum's
-- is_null output was discarded, leaving nulls[i] as uninitialized heap memory.
-- pljs_setup_variable_paramlist() reads nulls[i] into param->isnull, so a NULL
-- JS bind (Datum 0) could get isnull=false; the planner's const-folder then
-- runs datumCopy() on a NULL varlena pointer -> SIGSEGV (this is why
-- create_mirror() crashed in eval_const_expressions when a bind was NULL). The
-- fix sets nulls[i] = is_null ? 'n' : ' '. Interleaving NULL and non-NULL text
-- binds proves both the crash-avoidance and correct null flags.
DO $$
  const row = pljs.execute('SELECT $1::text AS a, $2::text AS b, $3::int AS c', [null, 'x', null])[0];
  const s   = pljs.execute("SELECT ($1::text || 'Y') AS s", [null])[0].s;   // forces const-folding of a NULL varlena
  pljs.elog(NOTICE, 'a_null=' + (row.a === null) + ' b=' + row.b + ' c_null=' + (row.c === null) + ' concat_null=' + (s === null));
$$ LANGUAGE pljs;
