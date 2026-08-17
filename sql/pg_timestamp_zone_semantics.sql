-- What a JS Date means for `timestamp` versus `timestamptz`, off UTC.
--
-- Both types go through the same pair of helpers,
-- pljs_convert_timestamptz_to_epoch() and pljs_convert_epoch_to_timestamptz(),
-- which do nothing but rebase between the Unix and PostgreSQL epochs.  No timezone
-- is applied in either direction.  That was raised in review as a possible bug for
-- `timestamp without time zone`, on the grounds that a JS Date is a UTC instant and
-- should not go through a tz-aware path.
--
-- Measured, the behaviour is:
--
--   * timestamptz  -- exact.  The stored value is already microseconds since
--     2000-01-01 UTC, so rebasing it yields the correct instant, and the round trip
--     is lossless.
--
--   * timestamp -- the stored wall clock is presented as the Date's *UTC* fields.
--     So '2024-01-15 12:00:00'::timestamp reads back as 2024-01-15T12:00:00.000Z
--     regardless of the session TimeZone, and writing that Date back stores 12:00
--     again.  Self-consistent, and lossless in both directions.
--
-- NB for tools/check-test-discrimination.sh: this is not a discriminating
-- regression test, and cannot be.  It pins behaviour that is deliberately
-- unchanged, so there is no fix to revert -- its value is that a future change to
-- either conversion path has to update it and thereby acknowledge the semantics.
--
-- We are deliberately not changing this. There is no timezone to apply to an
-- unzoned value without inventing one, presenting the wall clock through the UTC
-- accessors is the only mapping that round-trips, and it is what plv8 does -- so
-- changing it would break compatibility to no benefit. What was missing was any
-- coverage: the existing pg_datetime test pins timezone='UTC', where the two types
-- cannot be told apart. This test pins the distinction off UTC so a future change
-- to either path has to acknowledge it.
--
-- The consequence a caller has to know: for `timestamp`, use the UTC accessors
-- (getUTCHours, toISOString). The local-time accessors (getHours) will be shifted
-- by the *client's* zone, which has nothing to do with the database's.
CREATE EXTENSION IF NOT EXISTS pljs;

SET timezone = 'America/New_York';
SET datestyle = 'ISO, MDY';

CREATE FUNCTION tz_read_tstz(t timestamptz) RETURNS text LANGUAGE pljs AS $$
  return t.toISOString();
$$;
CREATE FUNCTION tz_read_ts(t timestamp) RETURNS text LANGUAGE pljs AS $$
  return t.toISOString();
$$;

-- The same instant, once zoned and once not.  12:00 EST is 17:00Z.
SELECT tz_read_tstz('2024-01-15 12:00:00-05'::timestamptz) AS tstz_noon_est;
SELECT tz_read_ts('2024-01-15 12:00:00'::timestamp)        AS ts_noon_unzoned;

-- Writing one Date at 17:00Z into each type.
CREATE FUNCTION tz_write_tstz() RETURNS timestamptz LANGUAGE pljs AS $$
  return new Date(Date.UTC(2024, 0, 15, 17, 0, 0));
$$;
CREATE FUNCTION tz_write_ts() RETURNS timestamp LANGUAGE pljs AS $$
  return new Date(Date.UTC(2024, 0, 15, 17, 0, 0));
$$;
SELECT tz_write_tstz()::text AS wrote_tstz;
SELECT tz_write_ts()::text   AS wrote_ts;

-- Round trips, which are the property that actually matters.
SELECT tz_read_tstz(tz_write_tstz()) AS tstz_round_trip;
SELECT tz_read_ts(tz_write_ts())     AS ts_round_trip;

-- And that the round trip does not depend on the session zone.
SET timezone = 'Asia/Tokyo';
SELECT tz_read_tstz(tz_write_tstz()) AS tstz_round_trip_tokyo;
SELECT tz_read_ts(tz_write_ts())     AS ts_round_trip_tokyo;
SELECT tz_read_ts('2024-01-15 12:00:00'::timestamp) AS ts_noon_unzoned_tokyo;

-- A zoned value read under two different session zones is the same instant, since
-- the zone only affects rendering.
SET timezone = 'America/New_York';
SELECT tz_read_tstz('2024-06-15 12:00:00+00'::timestamptz) AS tstz_summer_ny;
SET timezone = 'Asia/Tokyo';
SELECT tz_read_tstz('2024-06-15 12:00:00+00'::timestamptz) AS tstz_summer_tokyo;

-- date is a separate path (pljs_convert_date_to_epoch) and is also unzoned.
SET timezone = 'America/New_York';
CREATE FUNCTION tz_read_date(d date) RETURNS text LANGUAGE pljs AS $$
  return d.toISOString();
$$;
SELECT tz_read_date('2024-01-15'::date) AS date_midnight_utc;

RESET timezone;
RESET datestyle;
DROP FUNCTION tz_read_date(date), tz_write_ts(), tz_write_tstz(), tz_read_ts(timestamp), tz_read_tstz(timestamptz);
