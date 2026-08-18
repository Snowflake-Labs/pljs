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
| upstream now, 8 PRs | **50** |
| held — breaking data-format changes | 20 |
| folded into the fix they test or document | 17 |
| never leaves the fork (tooling, its repairs, one self-inflicted fix, fork CI) | 13 |

## Order, simplest first

| PR | branch | commits |
|---|---|---|
| 1 | `up/01-memory-corruption` | 3 |
| 2 | `up/02-error-reporting` | 8 |
| 3 | `up/03-crashes` | 12 |
| 4 | `up/04-lifetimes` | 5 |
| 5 | `up/05-leaks` | 6 |
| 6 | `up/06-operability` | 6 |
| 7 | `up/07-validator-and-cache` | 3 |
| 8 | `up/08-null-and-record` | 7 |

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

## Per-commit verification

The bar is every commit green, not every PR green. Use `tools/check-every-commit.sh`,
which does a clean build plus the full ordered suite at each commit. It is the gate
that caught two red commits in the current stack, and reordering is exactly the
operation that produces them. Also required before sending each PR:

- `tools/check-versions.sh` — PostgreSQL 16, 17, 18 and a low `pljs.memory_limit`
- `tools/installcheck-asan.sh` — zero sanitizer reports
- `tools/pljs-memory-matrix.sh` — green
- final tree equals the current tree, minus held/fork-only commits

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
