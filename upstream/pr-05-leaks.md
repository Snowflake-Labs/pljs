# Fix five allocation and reference leaks

None of these is visible in a single call; all of them accumulate in a long-lived
backend.

The one that matters most is a leaked QuickJS reference **per column, per row**, in the
composite conversion loops: `JS_GetPropertyStr()`'s result was never released on either
the null path or the conversion path. That is the hottest path in the extension for a
`RETURNS TABLE` function — its test fails with `out of memory` without the fix.

The rest: the SPI plan and parameter list allocated per iteration of
`pljs.execute()`/`plan.execute()` were freed only on success, so a raising query leaked
both — a short-lived child context deleted unconditionally replaces the per-path frees;
the property-name table from `JS_GetOwnPropertyNames()` and its atoms were dropped on
the floor during object key enumeration; two JavaScript references were taken and never
released in the storage helpers.

## Commits

- `Drop leaked JavaScript references in the storage helpers`
- `Free the per-iteration SPI plan and parameter list`
- `Free the property-name table from JS_GetOwnPropertyNames`
- `Release the per-column JSValue in the composite conversion loops`
- `Free the SPI plan and parameters when a parameterised execute raises`

Every commit builds and passes the full suite on its own, on PostgreSQL 16, 17 and 18.
