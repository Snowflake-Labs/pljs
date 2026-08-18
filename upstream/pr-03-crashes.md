# Fix nine ways a pljs function can take down the backend

Each of these terminates the connection, and most reproduce from plain SQL. Grouped
because they share a cause — PostgreSQL error handling and QuickJS reference counting
meeting at the same boundary — and because several report through the structured error
object added earlier in this stack.

## The ones worth reading first

**A composite column that converts to NULL crashes the backend.**
`pljs_jsvalue_to_datum()` signalled a SQL NULL with `PG_RETURN_NULL()`, which expands to
`fcinfo->isnull = true`. Every column of a composite is converted through
`pljs_jsvalue_to_datums()` or `pljs_jsvalue_to_record()`, and both pass `fcinfo == NULL`
— they report the null through the `is_null` argument instead. So the null return wrote
through a null pointer. Reaching it takes nothing exotic: `case DATEOID` handles only a
JavaScript `Date` and breaks out of the switch for anything else, so a plain string for
a date column falls through to the trailing `PG_RETURN_NULL()` — the one commented
"shut up, compiler", which turns out to be an ordinary path.

    CREATE TYPE r AS (d date);
    CREATE FUNCTION f() RETURNS SETOF r AS $$
      pljs.return_next({ d: 'not-a-date' });
    $$ LANGUAGE pljs;
    SELECT * FROM f();          -- SIGSEGV, write to 0x1c

`0x1c` is the offset of `FunctionCallInfoBaseData.isnull`. The scalar form of the same
conversion has a real `fcinfo` and quietly returns NULL, which is why this stayed
hidden: `RETURNS date` looks fine and only the composite form dies.

**`pljs.find_function()` crashes after enough lookups.** It returned the compiled
function straight out of the per-user cache. The cache entry is that value's only
owner, but a `JSValue` returned from a C function belongs to its caller, so QuickJS
decremented a count nobody had incremented. After roughly a thousand lookups the
refcount reaches zero while the entry is still cached, and the next call through the
cache terminates the backend. A plain call to the target mixed in among the lookups
makes it fire sooner. `pljs.start_proc` leaked the function and the call result on
every context creation for the same reason.

**A trigger could not use SPI at all.** `call_function()` and `call_srf_function()`
connect to SPI; `call_trigger()` never did. So not only DDL but a bare
`pljs.execute("SELECT 1")` failed inside a trigger — most of what a trigger is for.
Nothing in the suite covered it, because the existing trigger tests only inspect
`NEW`/`OLD` and the `TG_*` variables.

## The rest

A stale `SPI_tuptable` reused after `pljs.commit()`; a syscache pin held past the point
it was needed and leaked on one branch; a `pg_language` tuple read through
`Form_pg_database` (harmless only because both catalogs begin with an `Oid` at the same
offset); a PostgreSQL error raised inside `pljs.return_next` unwinding past the interpreter
instead of arriving as a catchable JavaScript exception, the way one from
`pljs.execute()` always has; a cursor error tearing down the whole SPI connection instead of the
statement; and the validator leaking its compiled function and context.

## Commits

- `Free the SPI tuptable after converting results`
- `Guard cursor fetch, move and close with an internal subtransaction`
- `Release the pg_proc pin on every branch`
- `Flush the error state in every PG_CATCH that reports to JavaScript`
- `Free the compiled function and context in the validator`
- `Free QuickJS state before dropping the cache's memory`
- `Read pg_language through its own struct and release the pin`
- `Do not let a PostgreSQL error longjmp out of pljs.return_next`
- `Take a reference before handing a cached function to JavaScript`
- `Connect to SPI in call_trigger, so a trigger can query`
- `Do not write through a null fcinfo when a composite column is NULL`

Every commit in this series builds from clean and passes the full ordered suite on its
own, verified per commit on PostgreSQL 17. The tip is additionally green on PostgreSQL
16, 17, 18 and 19beta3 — the versions this repository's CI matrix builds — with
`pljs.memory_limit=64`, and under AddressSanitizer with no reports.
