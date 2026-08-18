# Make the validator validate, and keep the function cache coherent

Three fixes to `CREATE FUNCTION` and the per-session compiled-function cache. These do
change when an error surfaces, which is why they are separate from the crash fixes.

## The validator never validated anything

`pljs_call_validator()` read `fcinfo->flinfo->fn_oid` — its own OID, not the OID of the
function being created, which arrives as `PG_GETARG_OID(0)`. So it fetched its own
`pg_proc` row and compiled that row's `prosrc`: the C symbol name
`pljs_call_validator`, which parses as a bare JavaScript identifier. The compile always
succeeded, every invalid body was accepted at `CREATE` time, and the syntax error
appeared only on the first call.

Correcting the OID alone is not enough. A pljs body is a function *body*, not a
program, so `return 42;` is a syntax error at top level — validating the raw `prosrc`
rejects almost every valid function. The wrapper construction is therefore extracted
from `pljs_compile_function()` and shared, so the validator and the compiler agree by
construction rather than by two copies staying in sync. `check_function_bodies = off`
still skips validation, so restoring a dump whose functions reference not-yet-created
objects keeps working.

## Repeated DDL grew the backend without bound

Creating or replacing a function called `pljs_cache_reset()`, which destroys every
per-user `JSContext`. QuickJS will not free a context that still has live references
into it, so the old one was not necessarily reclaimed and the next call built a fresh
one. A tight `CREATE OR REPLACE FUNCTION` loop reached roughly 536MB and then crashed
the backend within seconds. Dropping only the affected function's entry keeps the
context — which is per-user state, not per-function state. Measured on the same loop:
~20MB peak, no crash, and throughput rises because the common case no longer rebuilds
an interpreter per statement.

Whether the context survived is observable from JavaScript, which is what
`sql/pg_targeted_invalidation.sql` checks: anything held on `globalThis` lives in that
context, so it is still there after unrelated DDL exactly when the context was not
destroyed. Without the fix it reads `(gone)`.

## A replaced function kept running the old body elsewhere

The cache is per session and there is no syscache invalidation callback, so
`CREATE OR REPLACE FUNCTION` was invisible to every *other* backend: a session that had
already called the function ran the body it first compiled for the rest of its life.
Deploying a new definition required recycling every existing connection, and nothing
said so.

`pljs_func` already declared `fn_xmin` and `fn_tid` for this; they were never written
or read. They now record which `pg_proc` tuple an entry was compiled from and are
checked on every cache hit, which is what plpgsql does. This also settles `DROP
FUNCTION` followed by OID reuse, where the old body could otherwise run under the new
function's name.

## Commits

- `Validate the function being created, not the validator itself`
- `Invalidate only the replaced function, not the whole context cache`
- `Detect a stale cached function instead of running the old body`

Every commit in this series builds from clean and passes the full ordered suite on its
own, verified per commit on PostgreSQL 17. The tip is additionally green on PostgreSQL
16, 17, 18 and 19beta3 — the versions this repository's CI matrix builds — with
`pljs.memory_limit=64`, and under AddressSanitizer with no reports.
