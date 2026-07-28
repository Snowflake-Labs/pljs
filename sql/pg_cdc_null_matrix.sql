-- snowflake_cdc type-boundary matrix: NULL across every control type.
--
-- Every control-plane column the mirror procedures touch is nullable
-- (snapshot_lsn, last_operation_time, mirror_id, operation_description, ...),
-- so a SQL NULL must surface as JS null and a JS null must bind back to SQL
-- NULL for each type that crosses the boundary. This is the semantic complement
-- to pg_null_bind / pg_execute_params_nulls (which lock the crash-safety of the
-- NULL paths); here we assert the value semantics for the full control set.
DO $$
  const types = ['int8', 'text', 'bool', 'jsonb', 'timestamptz', 'uuid'];
  for (const ty of types) {
    const bound = pljs.execute('SELECT CAST($1 AS ' + ty + ') AS v', [null])[0].v;
    const read  = pljs.execute('SELECT NULL::' + ty + ' AS v')[0].v;
    pljs.elog(NOTICE, ty + ': bindNull=' + (bound === null) + ' readNull=' + (read === null));
  }
$$ LANGUAGE pljs;
