-- Regression test for NAMEOID bind encoding in pljs_jsvalue_to_datum().
--
-- NAMEOID used to be grouped with TEXTOID/VARCHAROID and encoded with
-- CStringGetTextDatum(), producing a varlena (text) datum. The name type is a
-- fixed-length NAMEDATALEN C string with no varlena header, so nameeq() read
-- garbage header bytes and every name-typed comparison silently returned no
-- rows -- breaking all system-catalog lookups (pg_namespace.nspname,
-- pg_class.relname, pg_attribute.attname, ...) done through a JS string bind.
-- The fix routes NAMEOID through DirectFunctionCall1(namein) to build a proper
-- NameData datum. Without it, ns_rows / int4_count come back 0 and the
-- round-trip is garbage.
DO $$
  const ns = pljs.execute("SELECT nspname FROM pg_namespace WHERE nspname = $1", ['pg_catalog']);
  const c  = pljs.execute("SELECT count(*)::int AS c FROM pg_type WHERE typname = $1", ['int4'])[0].c;
  const rt = pljs.execute("SELECT $1::name::text AS t", ['hello_name'])[0].t;
  pljs.elog(NOTICE, 'ns_rows=' + ns.length + ' int4_count=' + c + ' roundtrip=' + rt);
$$ LANGUAGE pljs;
