# Fix eight ways a pljs function can take down the backend

Each of these terminates the connection, and most reproduce from plain SQL. Grouped
because they share a cause — PostgreSQL error handling and QuickJS reference counting
meeting at the same boundary — and because several report through the structured error
object added earlier in this stack.

## The ones worth reading first

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
offset); errors escaping `pljs.return_next` by `siglongjmp`; a cursor error tearing down the whole SPI connection instead of the
statement; and the validator leaking its compiled function and context.

## Commits

- `Free the SPI tuptable after converting results`
- `Release the pg_proc pin on every branch`
- `Read pg_language through its own struct and release the pin`
- `Guard cursor fetch, move and close with an internal subtransaction`
- `Flush the error state in every PG_CATCH that reports to JavaScript`
- `Do not let a PostgreSQL error longjmp out of pljs.return_next`
- `Take a reference before handing a cached function to JavaScript`
- `Connect to SPI in call_trigger, so a trigger can query`
- `Free the compiled function and context in the validator`
- `Free QuickJS state before dropping the cache's memory`

Every commit builds and passes the full suite on its own, on PostgreSQL 16, 17 and 18.
