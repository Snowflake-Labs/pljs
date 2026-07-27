-- Stressor distilled from snowflake_cdc: boolean bind coercion.
--
-- A JS boolean bound to a bool column round-trips directly. Separately, the
-- mirror procedures deliberately avoid binding a *string* into a bool context
-- and instead compare SQL-side with "(? = 'true')" (see
-- apply_change_batches/helpers.js needs_snapshot). This test pins both the
-- direct JS-boolean bind and that text-compare idiom so the behaviour the
-- procedures rely on cannot regress.
DO $$
  const t = pljs.execute('SELECT $1::bool AS v', [true])[0].v;
  const f = pljs.execute('SELECT $1::bool AS v', [false])[0].v;
  pljs.elog(NOTICE, 'jsbool: t=' + t + ' f=' + f + ' types=' + (typeof t) + '/' + (typeof f));

  // the "(? = 'true')" needs_snapshot idiom
  const yes = pljs.execute("SELECT ($1 = 'true') AS b", ['true'])[0].b;
  const no  = pljs.execute("SELECT ($1 = 'true') AS b", ['false'])[0].b;
  pljs.elog(NOTICE, 'textcmp: true=' + yes + ' false=' + no);
$$ LANGUAGE pljs;
