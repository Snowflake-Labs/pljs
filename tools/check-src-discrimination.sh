#!/usr/bin/env bash
#
# For each commit: undo only its src/ change, keep its tests, and require the tests to
# fail.  A commit whose own tests still pass without its code has shipped no protection.
#
# WHY THIS SHAPE
#
# The question a maintainer asks while reading a series commit by commit is "does this
# commit's test actually cover this commit's change?"  So the revert has to be scoped to
# src/ at that commit -- not to the whole tree, and not at the tip.  In a linear series
# `git checkout <commit>^ -- src/` is exactly that commit's source change undone, with
# sql/, expected/ and the Makefile left as the commit wrote them.
#
# FOUR THINGS THIS GETS RIGHT THAT A NAIVE VERSION DOES NOT
#
# 1. A crash counts as discriminating.  Several fixes here are for segfaults, so without
#    the fix the backend dies rather than printing a diff.  pg_regress reports that as a
#    failure, which is the correct verdict -- but the server needs time to finish crash
#    recovery before the next pass, or the next commit reports a spurious failure.
#
# 2. Never regenerate expected output.  Regeneration is right when building a series and
#    catastrophic here: it would rewrite the test to match the unfixed behaviour and
#    report success.  This script only ever reads expected/.
#
# 3. Reset cluster state between passes.  Roles are cluster-level and survive a dropped
#    database, and a crashed test never reaches its own DROP ROLE -- so a leftover role
#    fails the next pass with "already exists", which looks like a code problem.
#
# 4. Distinguish "no tests" from "tests that do not discriminate".  A commit with no test
#    is a different conversation from one with a test that proves nothing, and some fixes
#    genuinely cannot be tested at this level (a heap over-read that changes no output).
#    Both are reported, neither is silently counted as a pass.
#
# Usage:
#   tools/check-src-discrimination.sh [base-ref]
#
# Needs PG_CONFIG and a running server (PGHOST/PGPORT).  Roughly a minute per commit:
# two clean builds and two suite runs.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

BASE="${1:-origin/main}"
DB="${CSD_DB:-contrib_regression}"

command -v "${PG_CONFIG:-pg_config}" >/dev/null || { echo "csd: PG_CONFIG not found" >&2; exit 2; }
[ -n "${PGHOST:-}" ] || { echo "csd: set PGHOST/PGPORT" >&2; exit 2; }
git diff --quiet && git diff --cached --quiet || { echo "csd: working tree dirty" >&2; exit 2; }

ORIGINAL_HEAD="$(git rev-parse HEAD)"
restore() {
  git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile 2>/dev/null
  make -s clean >/dev/null 2>&1; make -s >/dev/null 2>&1; make -s install >/dev/null 2>&1
}
trap restore EXIT

wait_for_server() {
  for _ in $(seq 1 90); do
    psql -X -qAt -d postgres -c 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

reset_cluster() {                       # $1 = space-separated test names
  wait_for_server || return 1
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1
  for t in $1; do
    for role in $(sed -nE 's/^[[:space:]]*CREATE (ROLE|USER)[[:space:]]+([A-Za-z0-9_]+).*/\2/p' \
                    "sql/$t.sql" 2>/dev/null); do
      psql -X -q -d postgres -c "DROP ROLE IF EXISTS $role" >/dev/null 2>&1
    done
  done
}

run() {                                  # $1 = tests; 0 = all passed
  reset_cluster "$1"
  make -s installcheck REGRESS="init-extension $1" >/tmp/csd_check.log 2>&1
}

crashed() { grep -qaE 'server closed the connection|connection to server|terminated by signal' /tmp/csd_check.log; }

DISCRIM=0; WEAK=0; NOTEST=0; EXPECTED=0; BROKEN=0
declare -a PROBLEMS=()

for commit in $(git rev-list --reverse "$BASE..$ORIGINAL_HEAD"); do
  subject="$(git log -1 --format=%s "$commit" | cut -c1-52)"
  short="${commit:0:9}"

  # Tests this commit adds or changes, and whether it touches src/ at all.
  # Both sql/ and expected/: a commit that adds no test file but changes the recorded
  # output of existing ones is tested by those -- the changed output IS its evidence.
  # Deriving from sql/ alone reported such commits as untested, which is how the
  # error-envelope and SQLSTATE commits were miscounted.
  tests="$( { git diff-tree --no-commit-id --name-only -r "$commit" -- sql/ \
                | sed -n 's|^sql/\(.*\)\.sql$|\1|p'
              git diff-tree --no-commit-id --name-only -r "$commit" -- expected/ \
                | sed -n 's|^expected/\(.*\)\.out$|\1|p'
            } | sort -u \
            | while read -r t; do [ -f "sql/$t.sql" ] && echo "$t"; done \
            | tr '\n' ' ' | xargs || true)"
  touches_src="$(git diff-tree --no-commit-id --name-only -r "$commit" -- src/ | grep -c . || true)"

  if [ "${touches_src:-0}" -eq 0 ]; then
    printf "  %s  %-52s  no src change, skipped\n" "$short" "$subject"
    continue
  fi
  if [ -z "$tests" ]; then
    printf "  %s  %-52s  NO TEST\n" "$short" "$subject"
    NOTEST=$((NOTEST + 1))
    PROBLEMS+=("$short no test -- $subject")
    continue
  fi

  # Commit's tests, commit's parent's source.
  git checkout -q "$commit" -- src/ sql/ expected/ Makefile 2>/dev/null
  git checkout -q "$commit^" -- src/ 2>/dev/null || { printf "  %s  no parent src\n" "$short"; continue; }

  make -s clean >/dev/null 2>&1
  if ! make -s >/tmp/csd_build.log 2>&1; then
    printf "  %s  %-52s  parent src does not build\n" "$short" "$subject"
    BROKEN=$((BROKEN + 1))
    git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile
    continue
  fi
  make -s install >/dev/null 2>&1

  if run "$tests"; then
    without="passed"
  elif crashed; then
    without="crashed"
  else
    without="failed"
  fi

  # Now with the commit's own source, to be sure the test is not simply broken.
  git checkout -q "$commit" -- src/ 2>/dev/null
  make -s clean >/dev/null 2>&1
  make -s >/dev/null 2>&1
  make -s install >/dev/null 2>&1
  if run "$tests"; then with="passed"; else with="failed"; fi

  # A test may declare that it cannot discriminate, with its reason.
  self_declared=0
  for t in $tests; do
    if sed 's/^[[:space:]]*--[[:space:]]*//' "sql/$t.sql" 2>/dev/null | tr '\n' ' ' \
         | grep -qiE 'coverage rather than a regression test|cannot be written at this level|does not discriminate|no reproduction|passes with and without'; then
      self_declared=1
    fi
  done

  if [ "$with" != "passed" ]; then
    printf "  %s  %-52s  NOT GREEN on its own source\n" "$short" "$subject"
    PROBLEMS+=("$short not green on its own source -- $subject")
    BROKEN=$((BROKEN + 1))
  elif [ "$without" = "crashed" ]; then
    printf "  %s  %-52s  discriminates (backend dies without it)\n" "$short" "$subject"
    DISCRIM=$((DISCRIM + 1))
  elif [ "$without" = "failed" ]; then
    printf "  %s  %-52s  discriminates\n" "$short" "$subject"
    DISCRIM=$((DISCRIM + 1))
  elif [ "$self_declared" = "1" ]; then
    printf "  %s  %-52s  cannot discriminate, and says so\n" "$short" "$subject"
    EXPECTED=$((EXPECTED + 1))
  else
    printf "  %s  %-52s  PASSES WITHOUT THE FIX\n" "$short" "$subject"
    PROBLEMS+=("$short passes without the fix -- $subject ($tests)")
    WEAK=$((WEAK + 1))
  fi

  git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile
done

TOTAL=$((DISCRIM + WEAK + NOTEST + EXPECTED + BROKEN))
echo
echo "═══ summary ═══"
echo "  commits examined:            $TOTAL"
echo "  discriminating:              $DISCRIM"
echo "  cannot discriminate (stated): $EXPECTED"
echo "  no test:                     $NOTEST"
echo "  passes without the fix:      $WEAK"
echo "  not green / build broken:    $BROKEN"

if [ "$TOTAL" -eq 0 ]; then
  echo; echo "csd: FAIL examined 0 commits"; exit 1
fi
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  echo
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
  echo; echo "csd: FAIL"; exit 1
fi
echo; echo "csd: OK"
