# Build against PostgreSQL 19, and fix three memory-safety bugs at the JavaScript boundary

Three independent defects, each with a regression test. None changes behaviour that
correct code could observe, so they are safe to take on their own and are the ones
worth backporting.


## First: pljs does not currently build against PostgreSQL 19

`.github/workflows/build_and_test.yml` already tests `REL_19_STABLE`, and the tree does
not compile against it. `src/types.c` calls `strftime()` and `gmtime()` through a
transitive include that PostgreSQL 19 dropped, and passes a `Datum` directly to
`VARDATA()`/`VARSIZE_ANY_EXHDR()`, which is no longer an implicit conversion. Whether
those are warnings or errors is a property of the compiler — gcc on the current runner
image warns, clang stops — so the CI leg is one image update from going red. Four lines,
no behaviour change, and it is what makes the rest of this series verifiable on 19.

## 1. Heap overrun converting a 32-bit typed array to bytea

The `BYTEAOID` case iterated to `bytes_per_element * length` while indexing the typed
array by element and writing `array_copy[i]`, where `array_copy` holds `length`
elements. Converting an `Int32Array` therefore wrote four times past the end of the
allocation. `SET_VARSIZE` used the correct size, so the *output* was right and the
corruption was silent — the worst kind: allocator-dependent, and it surfaces as an
unrelated crash somewhere else.

## 2. Unterminated string and heap over-read in the function cache

`prosrc` was copied two different wrong ways. One side allocated `strlen + 1` but
copied only `strlen` bytes; `palloc` does not zero, so the cached string had no
terminator. The other side then copied a fixed `NAMEDATALEN` bytes out of that
allocation, reading past its end for any body shorter than 63 characters. Both sides
now use `pstrdup`.

This one is not observable from plain SQL — it reads memory the process owns, so
nothing fails and no value changes. A sanitizer is required to see it.

## 3. Returning from inside `PG_TRY` leaves a dead `sigjmp_buf`

On the permission-denied path, `pljs_find_function` returned from inside its `PG_TRY`
block, so `PG_exception_stack` kept pointing at a stack frame that no longer existed.
The next `ereport(ERROR)` then `siglongjmp`ed into freed stack and killed the backend.
It now falls through to the shared return.

## Commits

- `Build against PostgreSQL 19`
- `Bound the typed-array to bytea copy by element count`
- `Copy prosrc with pstrdup instead of a fixed-length memcpy`
- `Do not return from inside PG_TRY in pljs_find_function`

Every commit in this series builds from clean and passes the full ordered suite on its
own, verified per commit on PostgreSQL 17. The tip is additionally green on PostgreSQL
16, 17, 18 and 19beta3 — the versions this repository's CI matrix builds — with
`pljs.memory_limit=64`, and under AddressSanitizer with no reports.
