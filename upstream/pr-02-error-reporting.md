# Preserve error detail across the SPI boundary, and use real SQLSTATEs

A SQL error raised inside `pljs.execute()` reached JavaScript as `execution error`
with everything useful discarded, and errors caused by user data reported `XX000`,
which a client cannot distinguish from an internal bug in the extension. This series
makes the error path carry what a caller needs to act on.

## What changes

The thrown JavaScript `Error` now carries the originating `message`, `detail`, `hint`
and the SQLSTATE, and those survive a `try`/`catch` in JavaScript. `ERROR: execution
error` becomes `ERROR: division by zero`; the expected-output churn in this series is
the evidence.

The SQLSTATE is exposed as `e.sqlstate`, the five-character string that every other PL
exposes, so `catch (e) { if (e.sqlstate === '23505') ... }` works. The packed numeric
`sqlerrcode` is kept alongside it.

Errors caused by user data get real codes — `ERRCODE_DATATYPE_MISMATCH`,
`ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE`, `ERRCODE_INVALID_PARAMETER_VALUE`. Genuinely
internal can't-happen conditions deliberately keep `XX000`, so a client dispatching on
SQLSTATE can still tell a bug in the PL from its own mistake.

Two diagnostics are rewritten to say what went wrong: a `return_next` column mismatch
now names the column and lists what the object actually supplied, capped so it cannot
flood the server log; and a `RETURNS record` function called without a column
definition list says so, instead of reporting `record type has not been registered`.

The six copies of the message-fallback expression are replaced by one helper, which
also stops the next such site from forgetting the empty-string guard. That commit
changes no behaviour by design, and `sql/pg_error_envelope_fields.sql` says so at the
top: it is coverage that pins the envelope a caller programs against, not a regression
test, and it passes with and without the change.

One note on how the argument-count SQLSTATE is asserted. It cannot be read from
JavaScript: that error is raised by a C function QuickJS called, and it unwinds past any
`try`/`catch` rather than arriving as an exception — unlike an error from
`pljs.execute()`. The test uses `\set VERBOSITY sqlstate` instead. Making
`plan.execute()` errors catchable the way `pljs.execute()`'s are is a separate change,
not attempted here.

## Commits

- `Flush the error state after copying it in pljs_execute`
- `Preserve the JavaScript error message and PostgreSQL detail across SPI`
- `Expose the SQLSTATE as e.sqlstate`
- `Report a JavaScript exception through one helper, and test the envelope`
- `Give the argument-count mismatch a real SQLSTATE`
- `Say which column and which properties mismatched in return_next`
- `Cap the property list in the return_next mismatch message`
- `Say that a record-returning function needs a column definition list`

Later fixes in this stack depend on this one: the structured error object is what they
report through.

Every commit in this series builds from clean and passes the full ordered suite on its
own, verified per commit on PostgreSQL 17. The tip is additionally green on PostgreSQL
16, 17, 18 and 19beta3 — the versions this repository's CI matrix builds — with
`pljs.memory_limit=64`, and under AddressSanitizer with no reports.
