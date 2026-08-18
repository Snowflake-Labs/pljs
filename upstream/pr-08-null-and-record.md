# Report SQL NULL correctly from composite, record and array returns

Seven fixes to how a JavaScript `null` or `undefined` becomes SQL NULL. These are mild
behaviour changes: in each case the previous result was a wrong value rather than an
error, so code relying on it will notice.

`PG_RETURN_NULL()` dereferences `fcinfo`, which is NULL on the bind-parameter path, so
NULL was reported by crashing rather than by setting the flag. The composite, record,
fallback and array paths now report NULL through `fcinfo` where they have it and
through an out-parameter where they do not.

A null or undefined value for an array type is now SQL NULL rather than an empty array
or a crash. `return_next(null)` on a composite set emits an all-NULL row instead of
being dropped. An `undefined` element inside a jsonb array becomes JSON `null` rather
than being omitted, which previously shortened the array and shifted every later index:
`[1, undefined, 3]` became `[1,3]`. And a single-column set reads the column value out
of a row object, rather than only working by accident of two other behaviours
interacting.

The null/undefined check is hoisted above the array and composite dispatches, which is
what makes the rest of these consistent rather than each path having its own answer.

## Commits

- `Avoid PG_RETURN_NULL with a NULL fcinfo`
- `Report SQL NULL through fcinfo on the composite, record and fallback paths`
- `Let a null or undefined value be SQL NULL for an array type`
- `Read the column value from a row object for a single-column set`
- `Emit a NULL row for return_next(null) on a composite set`
- `Convert an undefined jsonb array element to null instead of dropping it`
- `Treat undefined array elements as NULL without nulling the whole array`

Every commit builds and passes the full suite on its own, on PostgreSQL 16, 17 and 18.
