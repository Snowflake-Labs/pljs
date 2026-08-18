# Fix five allocation and reference leaks, and make the cap that measures them work

None of these is visible in a single call; all of them accumulate in a long-lived
backend.

The first commit is what makes the rest testable. `pljs.memory_limit` was read once, at
library load, so `SET pljs.memory_limit = 64` in a session changed the GUC without ever
reaching the interpreter — the runtime kept the 512MB default. A leak test that sets a
low cap and expects `out of memory` therefore passed whether or not the leak was fixed.
Applying the value to the live runtime on `SET` is a fix in its own right, and it is
placed first here because the two heap-leak tests below assert against it.

The one that matters most is a leaked QuickJS reference **per column, per row**, in the
composite conversion loops: `JS_GetPropertyStr()`'s result was never released on either
the null path or the conversion path. That is the hottest path in the extension for a
`RETURNS TABLE` function — its test fails with `out of memory` without the fix, under
the 64MB cap the first commit makes effective. It asserts against `pljs.memory_limit`
rather than `pg_backend_memory_contexts` deliberately: QuickJS allocates on the libc
heap, so that view cannot see a leaked JavaScript reference at all, and a test built on
it would pass either way.

The rest: the SPI plan and parameter list allocated per iteration of
`pljs.execute()`/`plan.execute()` were freed only on success, so a raising query leaked
both — a short-lived child context deleted unconditionally replaces the per-path frees;
the property-name table from `JS_GetOwnPropertyNames()` and its atoms were dropped on
the floor during object key enumeration; two JavaScript references were taken and never
released in the storage helpers.

## Commits

- `Re-apply pljs.memory_limit to the live runtime on SET`
- `Drop leaked JavaScript references in the storage helpers`
- `Free the per-iteration SPI plan and parameter list`
- `Free the property-name table from JS_GetOwnPropertyNames`
- `Release the per-column JSValue in the composite conversion loops`
- `Free the SPI plan and parameters when a parameterised execute raises`

Every commit in this series builds from clean and passes the full ordered suite on its
own, verified per commit on PostgreSQL 17. The tip is additionally green on PostgreSQL
16, 17, 18 and 19beta3 — the versions this repository's CI matrix builds — with
`pljs.memory_limit=64`, and under AddressSanitizer with no reports.
