-- Utility statements through pljs.execute: SHOW and EXPLAIN (FORMAT JSON).
--
-- Normalized so it stays stable across PG 16/17/18: we only assert that SHOW
-- returns one row with the expected key, and that EXPLAIN (FORMAT JSON) parses
-- to a structure with a top-level "Plan" key. No volatile costs/spacing are
-- compared (COSTS OFF; we never print the plan body).
DO $$
  const sp = pljs.execute('SHOW search_path');
  pljs.elog(NOTICE, 'SHOW: rows=' + sp.length + ' hasKey=' + ('search_path' in sp[0]));

  const row = pljs.execute('EXPLAIN (FORMAT JSON, COSTS OFF) SELECT 1')[0];
  const key = Object.keys(row)[0];
  let plan = row[key];
  if (typeof plan === 'string') plan = JSON.parse(plan);
  pljs.elog(NOTICE, 'EXPLAIN: isArr=' + Array.isArray(plan) + ' hasPlan=' + ('Plan' in plan[0]));
$$ LANGUAGE pljs;
