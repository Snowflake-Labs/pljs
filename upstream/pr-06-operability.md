# Make a runaway pljs function killable, and bound its stack

Four operability fixes. The first is the most severe thing in this stack for anyone
running pljs in production.

## Query cancellation was broken process-wide

`_PG_init()` installed its own `signal(SIGINT/SIGTERM/SIGABRT)` handlers, clobbering
PostgreSQL's for the life of the backend, and the QuickJS interrupt handler consulted
only pljs's private `os_pending_signals` bitmask. `statement_timeout` arrives as
`SIGALRM` → `QueryCancelPending`, which that bitmask never observes.

The consequences went well beyond pljs: **any backend that had ever run a pljs function
lost `statement_timeout`, `pg_cancel_backend()`, `pg_terminate_backend()` and fast
shutdown for every subsequent query in that session**, whatever language it was written
in. A `while(true)` JavaScript loop was unkillable short of `SIGKILL`, and because the
backend would not exit it blocked `pg_ctl restart` and held its database so
`pg_regress` could not drop it. Observed: 2h37m of CPU and roughly 40 blocked restart
attempts.

pljs no longer installs handlers. The interrupt handler reads `QueryCancelPending` and
`ProcDiePending` directly, and each `JS_Call`/`JS_Eval` caller runs
`CHECK_FOR_INTERRUPTS()` once QuickJS has unwound, so the real error is raised rather
than a JavaScript one. The vendored QuickJS marks the interrupt uncatchable, so
`try { while(true){} } catch(e) {}` cannot defeat it.

## The JavaScript stack budget was measured from the wrong place

`JS_NewRuntime()` records the C-stack top once, in `_PG_init`, and the budget is sized
relative to that anchor. Real JavaScript runs far deeper — SQL → JS → `pljs.execute` →
SQL → JS — and each level consumes stack the anchor knows nothing about. Because
`_PG_init` is the shallowest point in the backend, QuickJS believes it is nearer the end
of the stack than it is and refuses to continue: measured, a function recursing through
`pljs.execute()` failed at depth 250 while depth 150 succeeded, with plenty of stack
left. `JS_UpdateStackTop()` is now called at each entry into JavaScript, and deep
nesting is bounded by `check_stack_depth()` — the limit the DBA configured.

The budget is derived from `max_stack_depth`, and the test proves that: the achievable
recursion depth tracks it linearly (512kB → 268, 1024kB → 537, 2048kB → 1074,
4096kB → 2148), and the assertion fails if the explicit limit is not set.

## Also

`pljs.memory_limit` is applied to the live runtime on `SET`, rather than changing the
GUC without reaching the interpreter. And a failed `pljs.commit()`/`rollback()` is
re-thrown rather than converted to a catchable JavaScript exception, because there is no
valid transaction state to resume into — rejection *before* the commit starts stays
catchable, since nothing has changed at that point.

## Commits

- `Honor query cancellation instead of hijacking backend signals`
- `Bound the JavaScript stack size explicitly`
- `Re-anchor the JavaScript stack budget at each entry into JavaScript`
- `Make the derived stack budget observable in the regression suite`
- `Re-apply pljs.memory_limit to the live runtime on SET`
- `Re-throw a real commit or rollback failure`

Every commit builds and passes the full suite on its own, on PostgreSQL 16, 17 and 18.
