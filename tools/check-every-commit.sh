#!/usr/bin/env bash
#
# Run the FULL ordered regression suite at every commit in the series.
#
# This is a different question from tools/check-test-discrimination.sh, which asks
# whether each commit's own tests fail without its fix.  This asks whether each
# commit is green *in its entirety* -- which is what someone bisecting, or
# cherry-picking, or reviewing a single PR actually gets.
#
# The review raised it as a series-level note: a test whose expected output is
# written against post-fix behaviour, but which is added several commits before the
# fix, is red for every commit in between.  It named pg_cdc_bool as red across ten
# commits.  A per-commit run is the only way to know, and it is the one gate in the
# plan that had never actually been executed.
#
# Usage:
#   tools/check-every-commit.sh                 # every commit since the base
#   tools/check-every-commit.sh <base>          # since a given ref
#   CEC_FROM=40 tools/check-every-commit.sh     # skip the first 40 commits
#
# Needs a running server (PGHOST/PGPORT) and PG_CONFIG.  Expect roughly 40s per
# commit: a clean build plus the full suite.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

BASE="${1:-9ec6f7f}"
PGC="${PG_CONFIG:-pg_config}"
CEC_DB="${CEC_DB:-contrib_regression}"
FROM="${CEC_FROM:-0}"

command -v "$PGC" >/dev/null || { echo "cec: $PGC not found" >&2; exit 2; }
[ -n "${PGHOST:-}" ] || { echo "cec: set PGHOST/PGPORT to a running server" >&2; exit 2; }
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "cec: working tree is dirty; commit or stash first" >&2; exit 2
fi

ORIGINAL_HEAD="$(git rev-parse HEAD)"
restore() {
  git checkout -q "$ORIGINAL_HEAD" -- src/ sql/ expected/ Makefile 2>/dev/null
  make -s -C "$ROOT" clean >/dev/null 2>&1
  make -s -C "$ROOT" >/dev/null 2>&1
  make -s -C "$ROOT" install >/dev/null 2>&1
}
trap restore EXIT

wait_for_server() {
  local i
  for i in $(seq 1 60); do
    psql -X -qAt -d postgres -c 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Roles and the regression database survive a crashed test, and a leftover role
# breaks the next commit's run with "role already exists".  Same reasoning as in
# check-test-discrimination.sh.
reset_cluster() {
  wait_for_server
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $CEC_DB WITH (FORCE)" >/dev/null 2>&1
  for role in $(git show "$ORIGINAL_HEAD" --format= --name-only >/dev/null 2>&1; \
                git grep -hoE '^[[:space:]]*CREATE (ROLE|USER)[[:space:]]+[A-Za-z0-9_]+' \
                     "$ORIGINAL_HEAD" -- sql/ 2>/dev/null \
                | awk '{print $NF}' | sort -u); do
    psql -X -q -d postgres -c "DROP ROLE IF EXISTS $role" >/dev/null 2>&1
  done
}

TOTAL=0; GREEN=0; RED=0; BROKEN=0
declare -a REDS=()

i=0
for commit in $(git rev-list --reverse "$BASE..$ORIGINAL_HEAD"); do
  i=$((i + 1))
  [ "$i" -le "$FROM" ] && continue
  TOTAL=$((TOTAL + 1))

  subject="$(git log -1 --format=%s "$commit" | cut -c1-58)"
  git checkout -q "$commit" -- src/ sql/ expected/ Makefile 2>/dev/null

  make -s -C "$ROOT" clean >/dev/null 2>&1
  if ! make -s -C "$ROOT" >/tmp/cec_build.log 2>&1; then
    printf "  %3d %s  BUILD FAILED  %s\n" "$i" "${commit:0:9}" "$subject"
    REDS+=("${commit:0:9} BUILD FAILED -- $subject")
    BROKEN=$((BROKEN + 1))
    continue
  fi
  make -s -C "$ROOT" install >/dev/null 2>&1

  reset_cluster
  if make -s -C "$ROOT" installcheck >/tmp/cec_check.log 2>&1; then
    printf "  %3d %s  green         %s\n" "$i" "${commit:0:9}" "$subject"
    GREEN=$((GREEN + 1))
  else
    failed="$(grep -aE '^not ok' /tmp/cec_check.log | sed -E 's/^not ok +[0-9]+ +- +//' | awk '{print $1}' | tr '\n' ' ')"
    printf "  %3d %s  RED           %s\n      failing: %s\n" "$i" "${commit:0:9}" "$subject" "${failed:-unknown}"
    REDS+=("${commit:0:9} ${failed:-unknown} -- $subject")
    RED=$((RED + 1))
  fi
done

echo
echo "═══ summary ═══"
echo "  commits run: $TOTAL"
echo "  green:       $GREEN"
echo "  red:         $RED"
echo "  build fails: $BROKEN"
if [ "${#REDS[@]}" -gt 0 ]; then
  echo
  for r in "${REDS[@]}"; do echo "  - $r"; done
  echo
  echo "cec: FAIL"
  exit 1
fi
if [ "$TOTAL" -eq 0 ]; then
  echo
  echo "cec: FAIL ran 0 commits"
  exit 1
fi
echo
echo "cec: OK -- every commit is green on the full ordered suite"
