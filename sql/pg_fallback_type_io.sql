-- Types pljs has no explicit case for -- uuid, pg_lsn, money, time, interval,
-- inet, enums, domains, extension types -- go through the conversion fallback.
-- That fallback used to reinterpret the datum's bytes, which corrupted data two
-- different ways:
--
-- 1) A pass-by-value type was truncated with JS_NewInt32(), so an 8-byte value
--    lost its high half and surfaced as a negative int32.  '16/B374D848'::pg_lsn
--    read as -1284188088.  pg_lsn matters most here: LSNs are what the CDC
--    machinery is built on.
--
-- 2) A varlena type was read with VARDATA()/VARSIZE_ANY_EXHDR() and no
--    detoasting, so a compressed or out-of-line value yielded raw TOAST bytes.
--    A 102400-character domain-over-text value arrived in JavaScript as 1186
--    characters of compressed garbage -- silent corruption of exactly the large
--    values a mirror carries.
--
-- The fallback now converts through the type's own output function, and back
-- through its input function, so the round trip is lossless and unparseable
-- input raises instead of producing a corrupt datum.
SET timezone = 'UTC';
-- Pin the GUCs the printed representations depend on, so the output does not
-- vary with the cluster's locale or formatting settings.
SET lc_monetary = 'C';
SET intervalstyle = 'postgres';
SET datestyle = 'ISO, MDY';
CREATE EXTENSION IF NOT EXISTS pljs;

-- 1) 8-byte pass-by-value types are no longer truncated.
CREATE FUNCTION fb_text(v anyelement) RETURNS text AS $$ return String(v); $$ LANGUAGE pljs;

SELECT '16/B374D848'::pg_lsn AS original, fb_text('16/B374D848'::pg_lsn) AS via_js;
SELECT 'FFFFFFFF/FFFFFFFF'::pg_lsn AS original, fb_text('FFFFFFFF/FFFFFFFF'::pg_lsn) AS via_js;
SELECT '1234567890.12'::money AS original, fb_text('1234567890.12'::money) AS via_js;
SELECT '12:34:56.789'::time AS original, fb_text('12:34:56.789'::time) AS via_js;
SELECT '3 days 04:05:06'::interval AS original, fb_text('3 days 04:05:06'::interval) AS via_js;
SELECT '11111111-2222-3333-4444-555555555555'::uuid AS original,
       fb_text('11111111-2222-3333-4444-555555555555'::uuid) AS via_js;

-- 2) Round trips through the type, not through its bytes.
CREATE FUNCTION rt_lsn(v pg_lsn) RETURNS pg_lsn AS $$ return v; $$ LANGUAGE pljs;
CREATE FUNCTION rt_uuid(v uuid) RETURNS uuid AS $$ return v; $$ LANGUAGE pljs;
CREATE FUNCTION rt_interval(v interval) RETURNS interval AS $$ return v; $$ LANGUAGE pljs;
CREATE FUNCTION rt_money(v money) RETURNS money AS $$ return v; $$ LANGUAGE pljs;
CREATE FUNCTION rt_time(v time) RETURNS time AS $$ return v; $$ LANGUAGE pljs;
CREATE FUNCTION rt_inet(v inet) RETURNS inet AS $$ return v; $$ LANGUAGE pljs;

SELECT rt_lsn('16/B374D848')        = '16/B374D848'::pg_lsn          AS lsn,
       rt_lsn('FFFFFFFF/FFFFFFFF')  = 'FFFFFFFF/FFFFFFFF'::pg_lsn    AS lsn_max,
       rt_uuid('11111111-2222-3333-4444-555555555555')
                                    = '11111111-2222-3333-4444-555555555555'::uuid AS uuid,
       rt_interval('3 days 04:05:06') = '3 days 04:05:06'::interval  AS iv,
       rt_money('1234567890.12')    = '1234567890.12'::money         AS money,
       rt_time('12:34:56.789')      = '12:34:56.789'::time           AS t,
       rt_inet('192.168.0.1/24')    = '192.168.0.1/24'::inet         AS inet;

-- 3) TOASTed varlena values of a fallback type are detoasted, not read raw.
CREATE DOMAIN fb_domain AS text;
CREATE TABLE fb_toast (id int, d fb_domain, plain text);

INSERT INTO fb_toast VALUES
  (1, repeat('abcdefgh', 12800)::fb_domain, repeat('abcdefgh', 12800)),
  (2, repeat('x', 5000)::fb_domain, repeat('x', 5000)),
  (3, 'short'::fb_domain, 'short');

SELECT id, length(d) AS stored_len, pg_column_compression(d) AS compression
FROM fb_toast ORDER BY id;

-- The domain column must report the same length in JavaScript as the plain text
-- column holding the identical value.
DO $$
  var rows = pljs.execute('SELECT id, d, plain FROM fb_toast ORDER BY id');
  for (var i = 0; i < rows.length; i++) {
    pljs.elog(NOTICE, 'id=' + rows[i].id +
                      ' domain_len=' + rows[i].d.length +
                      ' text_len=' + rows[i].plain.length +
                      ' identical=' + (rows[i].d === rows[i].plain));
  }
$$ LANGUAGE pljs;

-- Same for a large uuid-free fallback type read out of storage.
CREATE TABLE fb_lsn (id int, l pg_lsn);
INSERT INTO fb_lsn VALUES (1, '0/0'), (2, '16/B374D848'), (3, 'FFFFFFFF/FFFFFFFF');

DO $$
  var rows = pljs.execute('SELECT id, l FROM fb_lsn ORDER BY id');
  for (var i = 0; i < rows.length; i++) {
    pljs.elog(NOTICE, 'id=' + rows[i].id + ' lsn=' + rows[i].l);
  }
$$ LANGUAGE pljs;

-- 4) Unparseable input raises instead of writing a corrupt datum.
CREATE FUNCTION bad_uuid() RETURNS uuid AS $$ return 'not-a-uuid'; $$ LANGUAGE pljs;
SELECT bad_uuid();

CREATE FUNCTION bad_lsn() RETURNS pg_lsn AS $$ return 'nonsense'; $$ LANGUAGE pljs;
SELECT bad_lsn();

-- An embedded NUL cannot be represented and is reported, not truncated.
CREATE FUNCTION nul_uuid() RETURNS uuid AS $$
  return '11111111-2222-3333-4444-5555555' + String.fromCharCode(0) + '55555';
$$ LANGUAGE pljs;
SELECT nul_uuid();

-- 5) Domain constraints are enforced, because the domain's input function runs.
CREATE DOMAIN fb_positive AS int CHECK (VALUE > 0);
CREATE FUNCTION dom_positive(v int) RETURNS fb_positive AS $$ return v; $$ LANGUAGE pljs;

SELECT dom_positive(5) AS ok;
SELECT dom_positive(-5) AS should_fail;

-- 6) Enums round-trip and reject unknown labels.
CREATE TYPE fb_mood AS ENUM ('sad', 'ok', 'happy');
CREATE FUNCTION rt_mood(v fb_mood) RETURNS fb_mood AS $$ return v; $$ LANGUAGE pljs;

SELECT rt_mood('happy') = 'happy'::fb_mood AS enum_roundtrips;
CREATE FUNCTION bad_mood() RETURNS fb_mood AS $$ return 'furious'; $$ LANGUAGE pljs;
SELECT bad_mood();

-- 7) NULL still travels as NULL in both directions for a fallback type.
CREATE FUNCTION null_lsn(v pg_lsn) RETURNS pg_lsn AS $$
  pljs.elog(NOTICE, 'received: ' + (v === null ? 'null' : typeof v));
  return null;
$$ LANGUAGE pljs;

SELECT null_lsn(NULL) IS NULL AS null_roundtrips;

DROP FUNCTION fb_text(anyelement);
DROP FUNCTION rt_lsn(pg_lsn);
DROP FUNCTION rt_uuid(uuid);
DROP FUNCTION rt_interval(interval);
DROP FUNCTION rt_money(money);
DROP FUNCTION rt_time(time);
DROP FUNCTION rt_inet(inet);
DROP FUNCTION bad_uuid();
DROP FUNCTION bad_lsn();
DROP FUNCTION nul_uuid();
DROP FUNCTION dom_positive(int);
DROP FUNCTION rt_mood(fb_mood);
DROP FUNCTION bad_mood();
DROP FUNCTION null_lsn(pg_lsn);
DROP TABLE fb_toast;
DROP TABLE fb_lsn;
DROP DOMAIN fb_domain;
DROP DOMAIN fb_positive;
DROP TYPE fb_mood;
RESET timezone;
RESET lc_monetary;
RESET intervalstyle;
RESET datestyle;
