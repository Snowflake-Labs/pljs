-- JSON/JSONB undefined-handling and in-place argument mutation (from plv8).
--
-- The mirror procedures build metadata objects with Object.assign and rely on
-- undefined-valued keys being dropped on serialization (JSON semantics), and on
-- being able to mutate a jsonb argument in place and return it. This pins both.
--
-- Note the asymmetry, which matches JSON.stringify(): an undefined object
-- *value* is dropped along with its key, but an undefined array *element*
-- becomes null and keeps its position.  Dropping the element instead would
-- shorten the array and shift every later index.
DO $$
  const obj = { a: 1, b: undefined, c: [1, undefined, 3], d: null };
  const j = pljs.execute('SELECT $1::jsonb AS j', [obj])[0].j;
  pljs.elog(NOTICE, 'keys=' + Object.keys(j).sort().join(',') +
                    ' c=' + JSON.stringify(j.c) + ' dNull=' + (j.d === null));
  pljs.elog(NOTICE, 'matches JSON.stringify: ' +
                    (JSON.stringify(j.c) === JSON.stringify([1, undefined, 3])));
$$ LANGUAGE pljs;

CREATE FUNCTION ju_mut(j jsonb) RETURNS jsonb LANGUAGE pljs AS $$
  j.x = (j.x || 0) + 1;
  j.added = 'new';
  j.gone = undefined;
  return j;
$$;
SELECT ju_mut('{"x":41,"gone":"bye"}'::jsonb) AS mutated;

DROP FUNCTION ju_mut(jsonb);
