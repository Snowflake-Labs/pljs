# Upstream submission: plan, map and runbook

Everything needed to rebuild this work as a clean series against `plv8/pljs`, decided
in advance so the long run is mechanical.

- `COMMIT-MAP.tsv` — every one of the 100 commits, mapped to a target PR or to
  `FOLD-*`, `HELD-*`, `FORK-ONLY-*`, `DROP-*`. Generated with a completeness assertion:
  an unassigned commit fails the generator.
- `pr-01…pr-08*.md` — the PR descriptions, written. Each opens with why the change
  matters and ends with its commit titles.
- `regen-regress.py` — derives the `Makefile` REGRESS list from the tests present.

## Where the 100 commits go

| bucket | commits |
|---|---|
| upstream now, 8 PRs | **43** |
| held — breaking data-format changes, and the null/record fixes entangled with them | 27 |
| folded into the fix they test or document | 17 |
| never leaves the fork (tooling, its repairs, one self-inflicted fix, fork CI) | 13 |

## Order, simplest first

| PR | branch | commits |
|---|---|---|
| 1 | `up/01-memory-corruption` | 4 |
| 2 | `up/02-error-reporting` | 8 |
| 3 | `up/03-crashes` | 11 |
| 4 | `up/04-lifetimes` | 6 |
| 5 | `up/05-leaks` | 6 |
| 6 | `up/06-operability` | 4 |
| 7 | `up/07-validator-and-cache` | 3 |
| 8 | `up/08-null-rows` | 1 |

Counts are generated from the branch, not maintained by hand — `pr-NN` commit lists are
rewritten from `git log` so they cannot drift from what is actually being sent.

PR 3 depends on PR 2 — four of its commits report through the structured error object
that PR 2 introduces. Everything else is independent, so 4–8 can go in parallel once 3
lands. Send PR 1 alone first and say nothing about the rest.

The 20 held commits are **not** sent as code. Open an issue with `NOTES.md` as the body
and ask how the maintainer wants 11 behaviour changes handled — including whether he
wants the compatibility GUC we chose not to provide.

Audience: `plv8/pljs` is Jerry Sievert's, with Regina Obe and others. Nobody upstream
has seen this work, so every PR stands alone.

## Method: verified, not assumed

Proven in a scratch worktree rooted at `origin/main`: three commits cherry-picked in
the new order, each rebuilt and run against the full suite — green at 22, 22 and 23
tests as they are added.

Per commit:

1. `git cherry-pick -n <sha>`
2. On a `Makefile` conflict — expected on nearly every test-adding commit — restore
   upstream's `Makefile` and re-derive REGRESS. Never merge it. The only difference
   between upstream's `Makefile` and ours is that list, asserted before resolving; if a
   commit ever changes it for another reason the apply stops.
3. `regen-regress.py` again, so the list matches the tests present.
4. Commit with a **new, clean-room** message.
5. Build, install, run the full suite. Red stops the run.

`regen-regress.py` is validated: with all 96 tests present its output is byte-identical
to the finished `Makefile`.

## What the shakedown found before any history was rewritten

- **Upstream builds clean on PostgreSQL 18.** Our PG 18 break was self-inflicted by our
  own `pg_noreturn` helper, so there is no portability fix to send. The shim belongs
  inside the error-reporting commit that introduces the helper, written correctly from
  the start. The commit that fixed it is `FORK-ONLY`.
- **The `DateStyle` hint fix modifies `sql/pg_datetime.sql`, which is ours**, so it
  cannot lead a series; it belongs with whichever PR carries that test.
- **Only two hard dependency edges exist** across all 100 commits: `js_throw_error_data`
  → four later crash fixes, and `pljs_cache_function_remove` → stale-cache detection.
  Every other helper arrives with all its call sites.
- **A data directory under `/tmp` is unsafe.** macOS's midnight cleanup deleted files
  from under a running postmaster, corrupting the cluster mid-session. The dev instance
  now lives in `~/pg-install/devdata_pg17` with its socket in `~/pg-install/devsock`.
  `check-versions.sh` and `installcheck-asan.sh` still use `/tmp` and must be moved
  before a long run.

## Clean-room rewriting: measured surface

Nothing may hint at a prior iteration, a reviewer, or this fork. Counted:

| surface | count |
|---|---|
| commit messages citing a review, a fork PR number, or an earlier round | **58 of 100** |
| `sql/` files with such references | **16 of 96** |
| their `expected/` twins (psql echoes input) | 16 |
| `src/` comments | 1 |

Rules: describe the defect and its consequence, never its discovery; keep the
reasoning, drop coordinates; no "as asked", "previously", "in this series", or
`tools/…` paths, since the tooling does not ship. Where a test cannot discriminate,
keep the explanation — an upstream reader needs it — and state it without referring to
a sweep that will not exist there.

## Two rules that make the reorder safe

Found by hitting them, not by planning. Both are load-bearing.

### 1. An error-text or SQLSTATE change belongs to the commit that owns the error site

A commit whose only job is to retroactively change messages or SQLSTATEs across many
sites cannot be placed in any order: it edits the expected output of tests that, in a
reordered series, do not exist yet. `fix: give user data-type errors a real SQLSTATE`
was exactly this — 8 hunks across 2 files, each at a different error site, plus 5
`expected/` edits.

It is therefore not a commit. Its hunks travel with whichever commit introduces each
site, which is computable:

| error site | owner | travels with |
|---|---|---|
| `plan expected %d arguments…` | pre-existing upstream | ships now, as its own small commit |
| `value is not an Array` | `86c56b8` | PR 8 |
| `ArrayBuffer, or typed array` | `20af343` | held |
| `could not convert…to a string` | `20af343` | held |

You cannot give a real SQLSTATE to an error that does not exist yet, so this is the
only coherent split. Apply the same test to any other commit that edits messages
broadly.

### 2. `expected/` output is derived, so regenerate it — never inherit it

32 of the 75 added `expected/` files are edited after being added, because they track
behaviour as it changes. Inheriting an old version into a reordered series produces a
red commit whose diff looks like a regression but is only staleness.

So: whenever a commit adds or modifies a test, generate its `expected/` from the tree
at that commit rather than taking the version recorded in the original history. The
`sql/` file is authored content; the `.out` file is output. Generating it is correct by
construction, and the per-commit suite run is what proves it.

The one discipline this needs: read every generated diff. A regenerated file that
silently absorbs a real regression is the failure mode, which is why the per-commit run
is a gate and not a formality.

## Per-commit verification

The bar is every commit green, not every PR green. Use `tools/check-every-commit.sh`,
which does a clean build plus the full ordered suite at each commit. It is the gate
that caught two red commits in the current stack, and reordering is exactly the
operation that produces them. Also required before sending each PR:

- `tools/check-versions.sh` — PostgreSQL 16, 17, 18, 19beta3 and a low
  `pljs.memory_limit`. 19 matters: it is in upstream's CI matrix, and the tree did not
  compile against it — `strftime`/`gmtime` reached through an include PostgreSQL 19
  dropped, and a `Datum` passed where a pointer is wanted. Both are upstream's own code
  and `origin/main` fails the same way; their CI stays green only because gcc warns
  where clang errors. Fixed as the first commit of the series.
- `tools/installcheck-asan.sh` — zero sanitizer reports
- `tools/pljs-memory-matrix.sh` — green
- final tree equals the current tree, minus held/fork-only commits

## What the src-discrimination gate found

`tools/check-src-discrimination.sh` undoes each commit's `src/` change, keeps its tests,
and requires the tests to fail. A commit whose own test still passes without its code has
shipped no protection. Running it changed the series materially:

| | before | after |
|---|---|---|
| discriminating | 22 | **30** |
| passes without its fix | 5 | **0** |
| no test, with a stated reason | 1 | **12** |
| no test, undeclared | 14 | **0** |

Four things it caught that per-commit greenness did not:

1. **A crash this series introduced.** `Re-throw a real commit or rollback failure`
   calls `PG_RE_THROW()` from a C function QuickJS called, which unwinds past the
   interpreter's frame list; the next JavaScript call in the session faults. Upstream
   does not have this bug — we would have added it. Commit dropped; see the PR 6
   description for the reproduction.
2. **A pre-existing upstream crash**, found while trying to make an inert test
   discriminate: a composite column converting to NULL writes through a null `fcinfo`.
   Reproduces on `origin/main`. Now fixed with a test, in PR 3.
3. **A test that asserted its own sanity check.** `pg_return_next_error_frames` used a
   value that only raises once the held integer range check exists, so the conversion
   never failed — and the recorded output was
   `srf failed as expected: expected the conversion to fail`, the message its own guard
   emits. It had been passing by asserting that its assertion misfired.
4. **Two tests measuring nothing.** The `SET pljs.memory_limit` fix landed *after* the
   heap-leak tests that depend on it, so they ran under the 512MB default instead of the
   64MB they set; and the stack-budget fix computes `max_stack_depth / 2`, which at the
   2048kB default equals `JS_DEFAULT_STACK_SIZE` exactly, so the suite passed whether or
   not the limit was applied.

The two remaining categories are honest, not hidden: a commit with no test says so in its
message and why. The gate treats an undeclared missing test as a failure and a declared
one as a pass, so the verdict stays actionable.

## Runbook

1. Fresh worktree at `origin/main`; copy `deps/` **without** its nested `.git`, or the
   build fails with "not a git repository".
2. Adopt upstream's Windows jsonb fix; we still carry that bug.
3. For each PR in order, apply its commits from `COMMIT-MAP.tsv` using the loop above,
   writing the new message from the matching `pr-NN` file's commit list.
4. Run `check-every-commit.sh` **per finished PR**, not once at the end.
5. Cut the branch, push, open only PR 1.
6. Confirm sign-off requirements with the maintainer; no DCO config found, but that is
   a grep rather than an answer.

## Environment

- `PGHOST=~/pg-install/devsock PGPORT=55917 PGUSER=postgres` (the role is created
  explicitly; `initdb` names the superuser after the OS user).
- `gh` flips its active account intermittently. Assert `gh api user --jq .login` before
  any write, and switch-and-act in one invocation.
