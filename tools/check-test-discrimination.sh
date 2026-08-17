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

run_tests() {  # $1 = space-separated test names -> 0 if all passed
  local tests="$1"
  make -s -C "$ROOT" installcheck REGRESS="init-extension $tests" >/tmp/ctd_check.log 2>&1
}

for commit in $(git rev-list --reverse "$BASE..HEAD"); do
  # Which tests does this commit define?
  mapfile -t tests < <(git show --name-only --format= "$commit" -- sql/ \
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

  if run_tests "$testlist"; then
    without="passed"
  else
    without="failed"
  fi

  # Now with the commit's own source.
  git checkout -q "$commit" -- src/ 2>/dev/null
  make -s -C "$ROOT" >/dev/null 2>&1
  make -s -C "$ROOT" install >/dev/null 2>&1
  if run_tests "$testlist"; then
    with="passed"
  else
    with="failed"
  fi

  # Is any of these tests self-declared coverage-only?
  is_coverage=0
  for t in "${tests[@]}"; do
    if git show "$commit:sql/$t.sql" 2>/dev/null \
         | grep -qi 'not a discriminating regression test'; then
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
    echo "    PROBLEM: passes without the fix -- not a regression test"
    PROBLEMS+=("${commit:0:9} passes without the fix -- $subject ($testlist)")
    FAILED=$((FAILED + 1))
  fi

  git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile
done

echo
echo "═══ summary ═══"
echo "  discriminating:        $PASS"
echo "  coverage-only (known): $COVERAGE"
echo "  skipped:               $SKIPPED"
echo "  problems:              $FAILED"
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  echo
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
  echo
  echo "ctd: FAIL"
  exit 1
fi
echo
echo "ctd: OK"
