-- Date / timestamp marshalling between PostgreSQL and JS Date.
--
-- NB for tools/check-test-discrimination.sh: this test discriminates against an
-- earlier commit than the one that last touches it.  Each behaviour asserted here
-- was fixed by its own commit; the most recent change to this file only made a
-- server-generated HINT terse, because PostgreSQL 18 capitalises the GUC name in it
-- where 16 and 17 do not.  A portability change cannot be discriminated against.
--
-- pljs marshals date / timestamp / timestamptz to a JS Date (epoch millis) and
-- back. The snowflake_cdc procedures read timestamptz control columns
-- (last_operation_time, last_apply_time) back as Dates, so this pins the
-- round-trip. Output is made deterministic with fixed timezone/datestyle/float
-- settings. Also pins the infinity divergence: 'infinity'::timestamptz surfaces
-- as a JS Invalid Date.
SET timezone = 'UTC';
SET datestyle = 'ISO, MDY';
SET extra_float_digits = 3;
DO $$
  const t = pljs.execute("SELECT '2024-03-15 12:34:56.789+00'::timestamptz AS t")[0].t;
  pljs.elog(NOTICE, 'timestamptz->Date: isDate=' + (t instanceof Date) + ' iso=' + t.toISOString());

  const d = pljs.execute("SELECT '2024-03-15'::date AS d")[0].d;
  pljs.elog(NOTICE, 'date->Date: isDate=' + (d instanceof Date) + ' iso=' + d.toISOString());

  const back = pljs.execute('SELECT $1::timestamptz AS t', [t])[0].t;
  pljs.elog(NOTICE, 'Date->timestamptz->Date: eq=' + (back.getTime() === t.getTime()));

  const inf = pljs.execute("SELECT 'infinity'::timestamptz AS t")[0].t;
  const ninf = pljs.execute("SELECT '-infinity'::timestamptz AS t")[0].t;
  pljs.elog(NOTICE, 'infinity: isDate=' + (inf instanceof Date) +
                    ' valid=' + (inf instanceof Date && !isNaN(inf.getTime())));
  pljs.elog(NOTICE, '-infinity: isDate=' + (ninf instanceof Date) +
                    ' valid=' + (ninf instanceof Date && !isNaN(ninf.getTime())));

  // CDC read-back: a last_operation_time-style timestamptz column is a Date.
  const now = pljs.execute('SELECT now() AS t')[0].t;
  pljs.elog(NOTICE, 'now() read-back isDate=' + (now instanceof Date));
$$ LANGUAGE pljs;
RESET timezone;
RESET datestyle;
RESET extra_float_digits;

-- A JavaScript *number* bound to a timestamp.
--
-- The non-Date branch now routes through the type's input function, which fixed
-- date/timestamp *strings* (previously silently NULL) but also means a raw epoch
-- number is rejected rather than quietly becoming NULL.  "Pass a millisecond
-- epoch" is a common JavaScript habit, so this is a behaviour change worth having
-- pinned and release-noted, per the PR 8 review.
CREATE FUNCTION dt_num() RETURNS timestamptz LANGUAGE pljs AS $$
  return 1577934245000;
$$;

-- Terse, because the HINT on this error names a GUC and PostgreSQL 18 capitalises
-- it ("DateStyle") where 16 and 17 do not ("datestyle").  The hint is the server's
-- wording, not pljs's, and pinning it would make this file fail on a version bump
-- for a reason that has nothing to do with the behaviour under test.
\set VERBOSITY terse
SELECT dt_num();
\set VERBOSITY default

-- The two forms that do work, for contrast: a Date, and a parseable string.
CREATE FUNCTION dt_date() RETURNS timestamptz LANGUAGE pljs AS $$
  return new Date(1577934245000);
$$;

CREATE FUNCTION dt_str() RETURNS timestamptz LANGUAGE pljs AS $$
  return '2020-01-02 03:04:05+00';
$$;

SET TIME ZONE 'UTC';
SELECT dt_date() AS from_date, dt_str() AS from_string;
RESET TIME ZONE;

-- date behaves the same way.
CREATE FUNCTION dt_date_num() RETURNS date LANGUAGE pljs AS $$ return 18263; $$;

SELECT dt_date_num();

DROP FUNCTION dt_num();
DROP FUNCTION dt_date();
DROP FUNCTION dt_str();
DROP FUNCTION dt_date_num();

