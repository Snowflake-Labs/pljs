-- Consolidated prepared-statement / cursor stress test.
--
-- cursor.sql already exercises fetch/move/free/close on a single plan; this
-- adds the angles the mirror procedures lean on that were not pinned together:
-- several live plans at once, one plan re-executed with different bind args,
-- explicit scroll-position checks, and the two use-after-lifetime error paths.
CREATE TABLE prep_tbl (i int, s text);
INSERT INTO prep_tbl SELECT g, 's' || g FROM generate_series(1, 5) g;

CREATE FUNCTION prep_stress() RETURNS void LANGUAGE pljs AS $$
  // (1) two independent live plans, interleaved
  const byId = pljs.prepare('SELECT s FROM prep_tbl WHERE i = $1', ['int']);
  const cnt  = pljs.prepare('SELECT count(*)::int AS n FROM prep_tbl WHERE i <= $1', ['int']);
  pljs.elog(NOTICE, 'interleave: ' + byId.execute([2])[0].s + '/' + cnt.execute([2])[0].n +
                    ' ' + byId.execute([4])[0].s + '/' + cnt.execute([4])[0].n);

  // (2) same plan re-executed with different args
  const got = [1, 3, 5].map(i => byId.execute([i])[0].s);
  pljs.elog(NOTICE, 're-execute: ' + got.join(','));
  byId.free();
  cnt.free();

  // (3) scrolling: in pljs, fetch(n)/move(n) return the NUMBER of rows moved
  //     (SPI semantics), while fetch() returns the next single row object.
  const plan = pljs.prepare('SELECT i FROM prep_tbl ORDER BY i');
  const cur = plan.cursor();
  const fetched2 = cur.fetch(2);       // count moved forward = 2
  const rowA = cur.fetch();            // next row after the 2 -> i=3
  const back2 = cur.fetch(-2);         // count moved backward
  const rowB = cur.fetch();            // next row after moving back
  cur.move(1);                         // skip one, returns count moved
  const rowC = cur.fetch();
  pljs.elog(NOTICE, 'scroll: fetched2=' + fetched2 + ' rowA=' + rowA.i +
                    ' back2=' + back2 + ' rowB=' + rowB.i + ' rowC=' + rowC.i);
  cur.close();
  plan.free();

  // (4) lifetime error paths (stable pljs messages)
  const p1 = pljs.prepare('SELECT 1 AS x');
  p1.free();
  try { p1.execute(); pljs.elog(NOTICE, 'execute-after-free: NO ERROR'); }
  catch (e) { pljs.elog(NOTICE, 'execute-after-free: ' + e.message); }

  const p2 = pljs.prepare('SELECT 1 AS x');
  const c2 = p2.cursor();
  c2.close();
  try { c2.fetch(); pljs.elog(NOTICE, 'fetch-after-close: NO ERROR'); }
  catch (e) { pljs.elog(NOTICE, 'fetch-after-close: ' + e.message); }
  p2.free();
$$;
SELECT prep_stress();

DROP FUNCTION prep_stress();
DROP TABLE prep_tbl;
