# Behaviour changes

Every user-visible change in this series, in one place. Several are corrections to
silent data corruption, so they turn something that quietly produced a wrong value
into either the right value or an error. Code that was relying on the wrong value
will notice.

No compatibility GUCs are provided. That is a deliberate choice: each of these was
either destroying data or returning something the caller could not detect as wrong,
and a switch to re-enable that would preserve the corruption for whoever left it on.

## 1. bytea reaches JavaScript as a `Uint8Array`, not a string

**Was:** `JS_NewStringLen()` decoded the bytes as UTF-8, so every byte sequence that
was not valid UTF-8 became U+FFFD and the original bytes were gone. Not re-encoded
— gone.

```sql
SELECT pljs_identity(decode('deadbeef', 'hex'));  -- returned \xdeadefbfbd
```

`0xde 0xad` became one replacement character, `0xbe 0xef` another, and writing back
re-encoded to UTF-8. Any bytea that was not pure ASCII was corrupted by a round
trip, silently.

**Now:** a `Uint8Array`, which carries the bytes exactly, still indexes, and still
has `.length`. This also matches plv8, so plv8's idiom for reading a bytea —
`String.fromCharCode.apply(null, bytea)` — works again; it previously threw.

**If you were relying on the old behaviour:** code doing string operations directly
on a bytea result must decode it. `arg + ""` is now `"1,2,3"` rather than a mangled
string; `arg.length` is a byte count rather than a character count; `arg.charCodeAt(0)`
no longer exists. This is the largest break in the series and a reasonable candidate
for a major-version note.

## 2. A JavaScript string is converted to the server encoding

**Was:** `JS_ToCStringLen()` returns UTF-8, and nothing validated it against the
server encoding, so on a non-UTF8 database a non-ASCII string was stored as raw
UTF-8 bytes into a column declared to hold something else — accepted silently, and
then a `pg_dump` that would not restore. Measured on a LATIN1 database: `héllo`
stored as 6 bytes `68c3a96c6c6f` rather than the correct 5-byte `68e96c6c6f`.

**Now:** converted via `pg_any_to_server()`. A character the server encoding cannot
represent raises `ERRCODE_UNTRANSLATABLE_CHARACTER` instead of being stored
unrestorably. On a UTF-8 server nothing changes and nothing extra is allocated.

## 3. Multidimensional arrays are rejected in both directions

**Was:** input flattened `{{1,2},{3,4}}` to `[1,2,3,4]`, losing the shape. Output was
worse — it did not fail, it produced pointers:

```sql
CREATE FUNCTION f() RETURNS int[] AS $$ return [[1,2],[3,4]]; $$ LANGUAGE pljs;
SELECT f();   -- {357119344,357119392}
```

Those are the inner `ArrayType` pointers reinterpreted as `int4`: numbers that look
like data.

**Now:** both directions raise. pljs represents SQL arrays as one-dimensional
JavaScript arrays; use `jsonb` for nested structure, or flatten explicitly.

**Also:** a JavaScript array aimed at any non-array, non-json type now raises rather
than being coerced. One consequence: `[]` returned for a `bool` used to be `true`
via truthiness and now raises. A plain object still yields truthiness — the array
shape had a corrupting path, the object shape did not.

**Note for plv8 users:** plv8 supports multidimensional arrays, so this widens the
porting gap.

## 4. Unhandled types convert through their I/O functions

**Was:** types with no explicit case were reinterpreted from their raw bytes.
`'16/B374D848'::pg_lsn` read as `-1284188088`; an 8-byte pass-by-value type
truncated to `int32`; a 102 400-character domain over `text` arrived as 1 186
characters of undetoasted TOAST bytes.

**Now:** routed through `OidOutputFunctionCall` / `OidInputFunctionCall`, so the
JavaScript-visible value is the type's text representation.

**If you were relying on the old behaviour:** the representation of `uuid`, `pg_lsn`,
`money`, `time`, `interval`, `inet`, enums and domains changes from garbage to a
string.

**One consequence to know about:** `money`, `interval`, `time` and `date` output text
depends on `lc_monetary`, `IntervalStyle` and `DateStyle`. The JavaScript-visible
value is therefore GUC-dependent, and a round trip is only stable if those settings
do not change between the read and the write. That is inherent to the approach and
still better than reading raw bytes.

## 5. Numeric conversions reject rather than alter

**Was:** out-of-range integers wrapped modulo the word size — `int4 ← 2147483648`
became `-2147483648`, `smallint ← 40000` became `-25536`, `int8 ← 2n**70n` became
`0`, and `NaN`/`Infinity` became `0`. A numeric *string* went through a double, so
`'9223372036854775807'` became `INT64_MIN` and text that was not a number became
`0`. `float4` had no range check at all, so an out-of-range value became `±Infinity`.

**Now:** all of these raise. Strings are parsed by the target type's input function.

**If you were relying on the old behaviour**, these inputs change meaning:

| input for `int4` | was | now |
|---|---|---|
| `"1e3"` | `1000` | error — `int4in` rejects exponent notation |
| `"1.5"` | `1` | error |
| `""` | `0` | error |
| `"  42  "` | error | `42` — `int4in` trims |

Exponent notation is a common JavaScript habit: `String(1e21)` is `"1e+21"`, so this
can fire on a number nobody typed as a string. A plain `Number` beyond 2^53 aimed at
`int8` is also rejected now, because a double cannot represent it exactly — use a
BigInt literal or a string.

## 6. A string bound to `bool` is parsed, not coerced

**Was:** `JS_ToBool()` reports every non-empty string as true, so `"false"`, `"f"`,
`"no"` and `"0"` were all true while `""` was false — the exact opposite of what the
text says.

**Now:** parsed by `bool`'s input function, which accepts what SQL accepts
(true/false, t/f, yes/no, on/off, 1/0, any case, optional whitespace) and raises
otherwise. `new String("false")` is unwrapped and follows the same path.

**If you were relying on the old behaviour:** `"maybe"` was `true` and now raises.

## 7. A JavaScript number is no longer accepted for a date or timestamp

**Was:** a non-Date value bound to a date/timestamp silently became NULL. That also
meant a valid date *string* was silently dropped.

**Now:** routed through the type's input function, so strings work — but a raw
millisecond epoch number raises `date/time field value out of range` rather than
becoming NULL. Pass a `Date`, or a string.

Separately, an invalid `Date` — which is what `'infinity'::timestamptz` reads back
as — used to be re-bound as a real, finite `2000-01-01`. It is now SQL NULL.

## 8. jsonb conversion is lossless and bounded

**Was:** `NaN`/`Infinity` produced `{"v": NaN}`, which is not valid JSON and cannot
be re-parsed by `jsonb_in` — breaking `pg_dump`/restore and every client parser. A
`Date` in a jsonb result came out as `{}`. An `undefined` array element was dropped,
shortening the array and shifting every later index, so `[1, undefined, 3]` became
`[1,3]`. A circular structure, a bare function, or deep nesting crashed the backend.

**Now:** `NaN`/`Infinity` emit JSON `null` (matching `JSON.stringify`), a `Date`
becomes its ISO string, `undefined` elements become `null`, and cycles and excessive
depth raise. Depth is bounded by `check_stack_depth()`, so it honours
`max_stack_depth` rather than a fixed limit.

## 9. `RETURNS jsonb[]` and `json[]` work at all

**Was:** they could not return anything — not objects, scalars, strings or nested
arrays. On stock upstream the same path read uninitialised memory as a type OID and
reported `cache lookup failed for type 2139062143` (`0x7F7F7F7F`).

**Now:** they work. This is a fix rather than a break, listed here because a value
that previously always errored may now succeed.

## 10. Errors carry more, and use real SQLSTATEs

- A thrown JavaScript error's own `.message` is the primary `errmsg`, rather than
  everything being flattened to `execution error` with the real message in
  `errdetail`.
- `detail`, `hint` and the SQLSTATE cross the SPI boundary, so a nested
  `pljs.execute()` no longer loses them.
- The SQLSTATE is exposed as `e.sqlstate` as well as the older `e.sqlerrcode`, so
  `catch (e) { if (e.sqlstate === '23505') ... }` works.
- User data-type mistakes now report a real SQLSTATE — `ERRCODE_DATATYPE_MISMATCH`,
  `ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE`, `ERRCODE_INVALID_PARAMETER_VALUE` — instead
  of `XX000`. Genuinely internal can't-happen conditions still report `XX000`, on
  purpose: a client dispatching on SQLSTATE should be able to tell a bug in the PL
  from its own mistake.
- A `return_next` column mismatch names the column, lists what the object supplied
  (capped at ten names plus the total), and states that property names are
  case-sensitive.
- A `RETURNS record` function called without a column definition list says so,
  instead of reporting `record type has not been registered`.

## 11. Text values reject an embedded NUL

**Was:** `CStringGetTextDatum()` used `strlen()`, so a JavaScript string containing
` ` was silently truncated at the NUL — `"a b"` became `"a"`.

**Now:** raises `ERRCODE_UNTRANSLATABLE_CHARACTER`. PostgreSQL text cannot hold a
NUL, so there is no correct value to store.

## Operational changes

These are not data-format changes, but they alter how a backend behaves.

- **Query cancellation works.** `_PG_init` previously installed its own
  `SIGINT`/`SIGTERM`/`SIGABRT` handlers, clobbering PostgreSQL's for the life of the
  backend — so any backend that had ever run a pljs function lost
  `statement_timeout`, `pg_cancel_backend()`, `pg_terminate_backend()` and fast
  shutdown, for *all* queries. A runaway JavaScript loop was unkillable short of
  `SIGKILL` and blocked DDL on its database indefinitely.
- **`pljs.memory_limit` applies at runtime.** `SET` previously changed the GUC
  without reaching the live interpreter. Lowering it below current usage does not
  reclaim anything — the next allocation fails with a JavaScript "out of memory".
- **An invalid function body is now rejected at `CREATE FUNCTION` time.** The
  validator was reading its own OID rather than the OID of the function being
  created, so it compiled the string `pljs_call_validator` -- which is a valid
  JavaScript identifier -- and accepted everything. A syntax error therefore only
  appeared on the first call. Existing functions with invalid bodies are unaffected
  until you next `CREATE OR REPLACE` them, at which point the DDL fails where it
  previously succeeded. `check_function_bodies = off` skips validation, as it always
  has, so dump/restore is unaffected.
- **A trigger can now use SPI.** `call_trigger()` never connected to SPI, so
  `pljs.execute()`, `pljs.prepare()` and cursors all failed inside a trigger
  function -- not only DDL, but a bare `pljs.execute("SELECT 1")`. Querying from a
  trigger is much of the point of a trigger, so this made a large part of that
  surface unusable. Upstream reports it as `execution error`; the error-surfacing
  changes above turn it into the real `current transaction is aborted`, which is
  what made it findable.
- **`pljs.find_function()` no longer crashes the backend.** It returned the
  compiled function straight out of the cache without taking a reference, while the
  engine assumed ownership of the returned value and decremented it. After enough
  lookups the refcount reached zero with the entry still cached, and the next call
  through it terminated the backend. A loop of `pljs.find_function('f')()` with a
  plain call to `f()` mixed in reproduces it in about a thousand iterations.
  `pljs.start_proc` was also leaking both the function and the call result on every
  context creation.
- **A replaced function takes effect in sessions other than the one that replaced
  it.** pljs caches compiled functions per session and registered no invalidation
  callback, so `CREATE OR REPLACE FUNCTION` was invisible to every other backend: a
  session that had already called the function kept running the body it first
  compiled, for the rest of its life. Deploying a new function body therefore
  required every existing connection to be recycled -- and nothing said so, which
  makes it the kind of bug that looks like a failed deploy. The cached entry now
  records which `pg_proc` tuple it came from and is rechecked on every call, the
  same mechanism plpgsql uses. This also fixes `DROP FUNCTION` followed by OID
  reuse, where the old body could run under the new function's name.
- **Repeated DDL no longer grows the backend without bound.** Creating or replacing a
  pljs function reset the *entire* compiled-function cache, destroying every
  per-user `JSContext`. QuickJS will not free a context that still has live
  references into it, so the old contexts were not necessarily reclaimed: a loop of
  `CREATE OR REPLACE FUNCTION` reached ~500 MB and then crashed the backend. Only
  the affected function's entry is dropped now. Measured on the same loop: ~20 MB
  peak, no crash.
- **A failed `pljs.commit()`/`rollback()` is re-thrown** rather than converted to a
  catchable JavaScript exception, because there is no valid transaction state to
  resume into. Rejection *before* the commit starts — calling it in an atomic
  context — is still catchable, since nothing has changed at that point.
