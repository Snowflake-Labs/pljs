# Emit a NULL row for return_next(null) on a composite set

`return_next(null)` on a set-returning function with a composite result type dropped the
row silently. A caller counting rows got a different answer from the one it asked for,
with nothing to indicate a row had been discarded — the failure is invisible unless you
already know the expected count.

It now emits a row whose every column is NULL, which is what a null row means in SQL.

`sql/pg_return_next_null_row.sql` covers a composite set with null rows interleaved with
real ones, so both the null and the non-null path are pinned.

## Commits

- `Emit a NULL row for return_next(null) on a composite set`

## Why this is one commit rather than a group

The other null-and-undefined fixes that would naturally sit beside it — reporting SQL
NULL through `fcinfo` on the composite, record and fallback paths; treating a
null or undefined value as SQL NULL for an array type; converting an `undefined` jsonb
array element to `null`; reading the column value out of a row object for a
single-column set — all depend on a larger rework of value conversion that is not part
of this series. Attempted separately, three of them conflict in `src/types.c` and two
terminate the backend, because the null checks and the conversion dispatch they sit in
are the same piece of code.

They are held back deliberately rather than split badly, and will follow with that
rework.

The commit builds and passes the full regression suite on its own.
