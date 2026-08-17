#!/usr/bin/env bash
#
# For each commit that adds or changes a test, check that the test actually fails
# without that commit's source change.
#
# A test that passes with the fix reverted is not a regression test -- it would pass
# just as happily if someone undid the fix tomorrow.  The review found three such
# tests in the first PR alone, by doing this by hand; this automates it.
#
# Method, per commit:
#   1. Check out the commit's sql/ and expected/ (the test as the commit defines it).
#   2. Check out the *parent's* src/ (the code without the fix).
#   3. Rebuild, install, run just that commit's tests.  They must FAIL.
#   4. Restore the commit's own src/, rebuild, run again.  They must PASS.
#
# Every test is paired with init-extension, which is the only test that runs
# CREATE EXTENSION pljs -- the Makefile's REGRESS list has no --load-extension, so
# any test run on its own fails for that reason alone and would look like a false
# positive here.
#
# A commit whose tests fail in step 4 is a worse problem than one that passes step 3:
# it means the commit is not green on its own terms.
#
# Coverage-only tests are expected to pass in step 3.  Mark them by putting
# "not a discriminating regression test" in the test file's header comment and they
# are reported as EXPECTED-COVERAGE rather than counted as failures.
#
# Usage:
#   tools/check-test-discrimination.sh                    # every commit since the base
#   tools/check-test-discrimination.sh <base>             # since a given ref
#   CTD_ONLY=pg_trigger_spi tools/check-test-discrimination.sh   # one test
#
# This needs a running server and takes a while: one rebuild per commit, twice.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

BASE="${1:-9ec6f7f}"
PGC="${PG_CONFIG:-pg_config}"
# The database pg_regress uses; matches the Makefile's --dbname.
CTD_DB="${CTD_DB:-contrib_regression}"

command -v "$PGC" >/dev/null || { echo "ctd: $PGC not found" >&2; exit 2; }
[ -n "${PGHOST:-}" ] || { echo "ctd: set PGHOST/PGPORT to a running server" >&2; exit 2; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ctd: working tree is dirty; commit or stash first" >&2
  exit 2
fi

ORIGINAL_HEAD="$(git rev-parse HEAD)"
restore() {
  git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile 2>/dev/null
  make -s -C "$ROOT" >/dev/null 2>&1
  make -s -C "$ROOT" install >/dev/null 2>&1
}
trap restore EXIT

PASS=0; FAILED=0; COVERAGE=0; SKIPPED=0
declare -a PROBLEMS=()

# Roles are cluster-level, so pg_regress dropping contrib_regression does not remove
# them.  That matters here because the without-fix pass often crashes the backend --
# that is the bug being tested -- so the test's own DROP ROLE never runs, and the
# with-fix pass then fails with "role already exists" and looks like a commit that is
# not green on its own source.  pg_find_function_no_perm hit exactly this.
wait_for_server() {
  local i
  for i in $(seq 1 60); do
    psql -X -qAt -d postgres -c 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "    WARNING: server did not come back within 60s" >&2
  return 1
}

drop_leftover_roles() {  # $1 = commit, $2 = space-separated test names
  local commit="$1" tests="$2" t role
  # Wait first.  This runs straight after a pass that may have crashed the backend,
  # and while the server is still recovering every psql here fails -- silently,
  # because the errors are discarded -- so the roles survive and the next pass dies
  # on "role already exists".  That is what kept pg_find_function_no_perm red after
  # the first two attempts at fixing this.
  wait_for_server

  # Drop the regression database first.  A crashed test leaves objects behind that
  # are owned by, or grant to, the role it created -- so DROP ROLE fails with
  # "cannot be dropped because some objects depend on it: 1 object in database
  # contrib_regression".  pg_regress recreates the database on its next run anyway,
  # so removing it here costs nothing and makes the roles droppable.  WITH (FORCE)
  # takes care of the session the crashed backend may have left behind.
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $CTD_DB WITH (FORCE)" >/dev/null 2>&1

  for t in $tests; do
    for role in $(git show "$commit:sql/$t.sql" 2>/dev/null \
                  | sed -nE 's/^[[:space:]]*CREATE (ROLE|USER)[[:space:]]+([A-Za-z0-9_]+).*/\2/p'); do
      psql -X -q -d postgres -c "DROP ROLE IF EXISTS $role" >/dev/null 2>&1
    done
  done
}

# Several of these tests crash the backend on purpose when run without their fix.
# The server then restarts and spends a moment in crash recovery, and pg_regress's
# first act is DROP DATABASE -- which fails with "the database system is in recovery
# mode", so the *next* pass looks like a failure that has nothing to do with the code
# under test.  Wait for the server to come back before each pass.

run_tests() {  # $1 = space-separated test names -> 0 if all passed
  local tests="$1"
  wait_for_server
  make -s -C "$ROOT" installcheck REGRESS="init-extension $tests" >/tmp/ctd_check.log 2>&1
}

for commit in $(git rev-list --reverse "$BASE..HEAD"); do
  # Which tests does this commit define?
  # No mapfile/readarray: macOS ships bash 3.2, where both are absent.  This used to
  # use mapfile, which failed on every commit -- and the run still reported OK,
  # because nothing checked that any commit had actually been evaluated.  See the
  # zero-commit guard at the end.
  tests=()
  while IFS= read -r line; do
    [ -n "$line" ] && tests+=("$line")
  done < <(git show --name-only --format= "$commit" -- sql/ \
           | sed -n 's|^sql/\(.*\)\.sql$|\1|p' | sort -u)
  [ "${#tests[@]}" -eq 0 ] && continue

  # Does it change any source?  A test-only commit has nothing to revert.
  if ! git show --name-only --format= "$commit" -- src/ | grep -q .; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ -n "${CTD_ONLY:-}" ]; then
    printf '%s\n' "${tests[@]}" | grep -qx "$CTD_ONLY" || continue
    tests=("$CTD_ONLY")
  fi

  subject="$(git log -1 --format=%s "$commit")"
  testlist="${tests[*]}"
  echo
  echo "─── ${commit:0:9} $subject"
  echo "    tests: $testlist"

  # The commit's tests, against the parent's source.
  git checkout -q "$commit" -- sql/ expected/ Makefile 2>/dev/null
  git checkout -q "$commit^" -- src/ 2>/dev/null || {
    echo "    SKIP (no parent src/)"; SKIPPED=$((SKIPPED + 1)); continue; }

  if ! make -s -C "$ROOT" >/tmp/ctd_build.log 2>&1; then
    # The parent's src/ with this commit's Makefile can legitimately fail to build
    # when the commit adds a source file; that is not a test-quality problem.
    echo "    SKIP (parent src/ does not build with this commit's Makefile)"
    SKIPPED=$((SKIPPED + 1))
    git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile
    continue
  fi
  make -s -C "$ROOT" install >/dev/null 2>&1

  drop_leftover_roles "$commit" "$testlist"
  if run_tests "$testlist"; then
    without="passed"
  else
    without="failed"
  fi

  # Now with the commit's own source.
  git checkout -q "$commit" -- src/ 2>/dev/null
  make -s -C "$ROOT" >/dev/null 2>&1
  make -s -C "$ROOT" install >/dev/null 2>&1
  drop_leftover_roles "$commit" "$testlist"
  if run_tests "$testlist"; then
    with="passed"
  else
    with="failed"
  fi

  # Two kinds of expected non-discrimination, both self-declared in the test header.
  # Read the markers from HEAD, not from this commit: a test may be labelled later
  # than the commit that introduced it, which is what happened to
  # pg_spi_freetuptable.
  #
  #   "not a discriminating regression test"
  #       The behaviour cannot be observed at this level at all -- a dangling pointer
  #       whose visibility depends on the allocator, or a contract violation that does
  #       not surface as a crash.  pg_spi_freetuptable and pg_cursor_plan_lifetime.
  #
  #   "strengthened after the commit that introduced it"
  #       The version at the introducing commit genuinely did not discriminate -- the
  #       review said so -- and it was fixed later.  The sweep runs the historical
  #       version, so it still reports the original weakness.  pg_stack_depth.
  #
  #   "discriminates against an earlier commit"
  #       The test is real, but this sweep pairs each test with the commit that adds
  #       the *file*, which is not always the commit that introduces the behaviour.
  #       A refactor that ships a test for behaviour added three commits earlier will
  #       always look non-discriminating here.
  # Match against the header with comment markers stripped, newlines folded and runs
  # of whitespace collapsed, case-insensitively.  The markers are prose in a wrapped
  # SQL comment, so the literal phrase is split across lines and prefixed with "--";
  # matching the raw text finds nothing, which is how these five silently went back to
  # being reported as problems.
  is_coverage=0
  for t in "${tests[@]}"; do
    head_src="$(git show "$ORIGINAL_HEAD:sql/$t.sql" 2>/dev/null \
                | sed 's/^[[:space:]]*--[[:space:]]*//' | tr '\n' ' ' | tr -s '[:space:]' ' ')"
    if printf '%s' "$head_src" | grep -qiE \
         'not a discriminating regression test|discriminates against an earlier commit|strengthened after the commit that introduced it'; then
      is_coverage=1
    fi
  done

  if [ "$with" != "passed" ]; then
    echo "    PROBLEM: not green on its own source (with fix: $with)"
    PROBLEMS+=("${commit:0:9} not green on its own source -- $subject")
    FAILED=$((FAILED + 1))
  elif [ "$without" = "failed" ]; then
    echo "    ok  fails without the fix, passes with it"
    PASS=$((PASS + 1))
  elif [ "$is_coverage" = "1" ]; then
    echo "    EXPECTED-COVERAGE  passes without the fix, and says so in its header"
    COVERAGE=$((COVERAGE + 1))
  else
    changed_since=""
    for t in "${tests[@]}"; do
      if ! git diff --quiet "$commit" "$ORIGINAL_HEAD" -- "sql/$t.sql" 2>/dev/null; then
        changed_since=" [test has been changed since this commit -- check HEAD's version]"
      fi
    done
    echo "    PROBLEM: passes without the fix -- not a regression test$changed_since"
    PROBLEMS+=("${commit:0:9} passes without the fix -- $subject ($testlist)$changed_since")
    FAILED=$((FAILED + 1))
  fi

  git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile
done

EVALUATED=$((PASS + COVERAGE + FAILED))

echo
echo "═══ summary ═══"
echo "  commits evaluated:     $EVALUATED"
echo "  discriminating:        $PASS"
echo "  coverage-only (known): $COVERAGE"
echo "  skipped:               $SKIPPED"
echo "  problems:              $FAILED"

# A sweep that evaluated nothing must not report success.  This is how the mapfile
# bug above went unnoticed: every commit errored out of the loop, and the summary
# printed four zeros and "OK".  Any gate that can pass by doing nothing is not a gate.
if [ "$EVALUATED" -eq 0 ]; then
  echo
  echo "ctd: FAIL evaluated 0 commits -- the sweep did not run"
  echo "     (check for shell errors above; this script needs git, make and a server)"
  exit 1
fi
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  echo
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
  echo
  echo "ctd: FAIL"
  exit 1
fi
echo
echo "ctd: OK"
