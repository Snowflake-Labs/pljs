# Fix prepared-plan and cursor lifetimes

Five fixes to how long a prepared plan and its portal live, and where their memory
comes from.

Plan data was allocated in the caller's short-lived context while the plan itself was
saved, so the plan outlived the state it pointed at. It now comes from
`CacheMemoryContext`. Note that the plan's `parserSetupArg` still points at a
stack-local `pljs_param_state`, which is why freeing the plan before that frame exits
is load-bearing rather than an optimisation; there is a comment saying so.

Unreachable plan handles are reclaimed by a GC finalizer rather than leaking until the
session ends, and an explicit `plan.free()` clears the handle's opaque pointer so the
finalizer cannot double-free afterwards.

A cursor now keeps its plan alive. `pljs.prepare(...).cursor(...)` leaves the plan
object unreachable the moment `.cursor()` returns, so the finalizer could
`SPI_freeplan()` a plan whose portal was still open and about to be re-entered by
`fetch`. `SPI_freeplan`'s contract says a plan in use must not be freed.

Being straight about the evidence for that last one: it has no reproduction. Under GC
pressure, with `CLOBBER_FREED_MEMORY`, and under AddressSanitizer with the fix
reversed, nothing reports. The portal holds a refcount on the `CachedPlan` rather than
the `CachedPlanSource` and does not appear to dereference the plansource during a
fetch. The fix rests on the documented contract, not on a crash, and the test says so
rather than implying otherwise.

## Commits

- `Allocate prepared plan data in CacheMemoryContext`
- `Free parstate on the pljs.prepare error path`
- `Reclaim prepared-statement plans with a GC finalizer`
- `Free the cursor's parameter arrays and mark the portal volatile`
- `Keep the prepared plan alive for the lifetime of its cursor`

Every commit builds and passes the full suite on its own, on PostgreSQL 16, 17 and 18.
