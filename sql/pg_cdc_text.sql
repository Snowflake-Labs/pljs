-- snowflake_cdc type-boundary matrix: text (extends pg_name_bind).
--
-- text carries every identifier and status the mirror procedures bind via
-- CAST(? AS TEXT) (mirror_name, schema/table/column names, operation_type).
-- The procedures also build SQL by hand with two escaping helpers --
-- escapeSqlLiteral (single-quote doubling) and quoteIdent (double-quote
-- doubling) -- which are only correct with standard_conforming_strings=on.
-- This pins the text round-trip at the awkward inputs (empty, multibyte,
-- quotes, backslash, long, NULL) and both escaping idioms.
SET standard_conforming_strings = on;
DO $$
  function t(x){ return pljs.execute('SELECT CAST($1 AS TEXT) AS v', [x])[0].v; }
  const cases = {
    empty:     '',
    ascii:     'orders',
    unicode:   'caf\u00e9_\u540d\u524d_\ud83d\ude80',
    quotes:    "O'Brien \"quoted\"",
    backslash: 'a\\b\\c',
    long:      'x'.repeat(1000),
  };
  for (const k in cases) {
    const r = t(cases[k]);
    pljs.elog(NOTICE, k + ': eq=' + (r === cases[k]) + ' len=' + r.length);
  }
  const n = pljs.execute('SELECT CAST($1 AS TEXT) AS v', [null])[0].v;
  pljs.elog(NOTICE, 'null: isNull=' + (n === null));

  // escapeSqlLiteral idiom: single-quote doubling, backslash stays literal.
  function escapeSqlLiteral(s){ return s.replace(/'/g, "''"); }
  const lit = "it's a \\ test";
  const litOut = pljs.execute("SELECT '" + escapeSqlLiteral(lit) + "' AS v")[0].v;
  pljs.elog(NOTICE, 'escapeSqlLiteral: eq=' + (litOut === lit));

  // quoteIdent idiom: double-quote doubling -> column alias survives verbatim.
  function quoteIdent(name){ return '"' + name.replace(/"/g, '""') + '"'; }
  const ident = 'weird "col" name';
  const row = pljs.execute('SELECT 1 AS ' + quoteIdent(ident))[0];
  pljs.elog(NOTICE, 'quoteIdent: hasKey=' + (ident in row) + ' val=' + row[ident]);
$$ LANGUAGE pljs;
RESET standard_conforming_strings;
