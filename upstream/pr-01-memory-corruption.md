# Fix three memory-safety bugs in the JavaScript boundary

Three independent defects, each with a regression test. None changes behaviour that
correct code could observe, so they are safe to take on their own and are the ones
worth backporting.

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

- `Bound the typed-array to bytea copy by element count`
- `Copy prosrc with pstrdup instead of a fixed-length memcpy`
- `Do not return from inside PG_TRY in pljs_find_function`

Every commit builds and passes the full regression suite on its own; tested against
PostgreSQL 16, 17 and 18.
