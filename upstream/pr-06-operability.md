# Make a runaway pljs function killable, and bound its stack

Three operability fixes. The first is the most severe thing in this stack for anyone
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

The interrupt check is widened at the same time, from `QueryCancelPending ||
ProcDiePending` to include `InterruptPending`, so a lost client connection, a recovery
conflict or an idle-in-transaction timeout also unwinds JavaScript. Those paths were
additionally leaking the exception value: the `JS_FreeValue` sat after a report that does
not return, so it was dead code.

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

## Not included: re-throwing a failed commit

A `pljs.commit()` that genuinely fails is still converted into a catchable JavaScript
exception, so a function can carry on running with no valid transaction state under it.
That is a real problem, and the obvious fix — `PG_RE_THROW()` from the `PG_CATCH` —
does not work: `pljs_commit()` is a C function that QuickJS called, so re-throwing
`siglongjmp`s past the interpreter's own frame list and the next JavaScript call in the
session faults. Reproduced with a deferred unique constraint, which fails at `COMMIT`:

    CALL p();                    -- p() swallows the failed commit
    SELECT f();                  -- f() calls pljs.commit(): backend dies

Fixing it properly means letting QuickJS unwind first and re-raising the saved error
once control is back in C — the shape the interrupt handler already uses — which is a
larger change than belongs in this series. Left for a follow-up rather than shipped
half-done.

`pljs.memory_limit` being applied to the live runtime on `SET` moved to the leaks PR,
where the heap-leak tests depend on it.

## Commits

- `Honor query cancellation instead of hijacking backend signals`
- `Bound the JavaScript stack size explicitly`
- `Re-anchor the JavaScript stack budget at each entry into JavaScript`
- `Widen the interrupt check, and stop leaking the exception value`

Every commit in this series builds from clean and passes the full ordered suite on its
own, verified per commit on PostgreSQL 17. The tip is additionally green on PostgreSQL
16, 17, 18 and 19beta3 — the versions this repository's CI matrix builds — with
`pljs.memory_limit=64`, and under AddressSanitizer with no reports.
