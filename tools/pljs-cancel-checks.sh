#!/usr/bin/env bash
#
# pljs-cancel-checks.sh - cross-session cancellation / liveness checks that a
# single-session pg_regress test cannot express.
#
# sql/pg_cancellation.sql covers statement_timeout (a self-inflicted SIGALRM in
# the same session). This tool covers the multi-session cases that matter for an
# operator babysitting a stuck mirror worker:
#
#   1. pg_cancel_backend() from another session interrupts a runaway pljs loop
#      promptly, the loop session gets a "canceling statement" error, and the
#      backend stays alive and usable afterwards.
#   2. pg_terminate_backend() from another session kills a runaway pljs loop
#      promptly and the loop session's connection is closed.
#   3. after both, the *server* is fine (a fresh connection works).
#
# These exercise the Phase 10 signal fix (patch 0029): before it, pljs installed
# its own SIGINT/SIGTERM handlers and a runaway JS loop ignored
# QueryCancelPending/ProcDiePending, so neither cancel nor terminate could stop
# it. Each check has a hard timeout; a check that does not stop the loop within
# it is a FAIL (the pre-fix behaviour would hang forever).
#
# Usage:
#   PGPORT=5432 PGHOST=/tmp tools/pljs-cancel-checks.sh
#   CANCEL_TIMEOUT=10 tools/pljs-cancel-checks.sh
#
set -uo pipefail

PORT="${PGPORT:-5432}"
HOST="${PGHOST:-/tmp}"
DB="${PGDATABASE:-postgres}"
TIMEOUT="${CANCEL_TIMEOUT:-10}"
PSQL=(psql -X -tA -p "$PORT" -h "$HOST" -d "$DB")

command -v psql >/dev/null 2>&1 || { echo "pljs-cancel-checks: psql not on PATH" >&2; exit 1; }

q() { "${PSQL[@]}" -c "$1" 2>/dev/null; }

"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pljs;" >/dev/null 2>&1

fail=0

# Start a runaway pljs loop in the background under a unique application_name so
# we can find its backend pid from the controller session. Returns the bg PID.
start_runaway() {
  local appname="$1"
  ( PGAPPNAME="$appname" psql -X -tA -p "$PORT" -h "$HOST" -d "$DB" \
      -c "SET application_name = '$appname'; DO \$\$ var x=0; while(true){x++;} \$\$ LANGUAGE pljs;" \
      >/dev/null 2>&1 ) &
  echo $!
}

find_backend_pid() {
  local appname="$1" pid=""
  for _ in $(seq 1 50); do   # up to ~5s for the loop to become active
    pid="$(q "SELECT pid FROM pg_stat_activity WHERE application_name='$appname' AND state='active' LIMIT 1")"
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}

wait_gone() {
  local bgpid="$1" i=0
  while kill -0 "$bgpid" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt $((TIMEOUT * 10)) ] && return 1
    sleep 0.1
  done
  return 0
}

# ---- check 1: pg_cancel_backend ----
echo "check 1: pg_cancel_backend interrupts a runaway pljs loop"
bg="$(start_runaway pljs_cancel_1)"
if beid="$(find_backend_pid pljs_cancel_1)"; then
  q "SELECT pg_cancel_backend($beid)" >/dev/null
  if wait_gone "$bg"; then
    echo "  ok: loop stopped after cancel"
  else
    echo "  FAIL: loop still running ${TIMEOUT}s after pg_cancel_backend"; fail=1; kill -9 "$bg" 2>/dev/null
  fi
else
  echo "  FAIL: could not observe the runaway backend as active"; fail=1; kill -9 "$bg" 2>/dev/null
fi

# backend must still be usable
alive="$(q 'SELECT 1')"
[ "$alive" = "1" ] && echo "  ok: server usable after cancel" || { echo "  FAIL: server not usable after cancel"; fail=1; }

# ---- check 2: pg_terminate_backend ----
echo "check 2: pg_terminate_backend kills a runaway pljs loop"
bg="$(start_runaway pljs_term_2)"
if beid="$(find_backend_pid pljs_term_2)"; then
  q "SELECT pg_terminate_backend($beid)" >/dev/null
  if wait_gone "$bg"; then
    echo "  ok: loop stopped after terminate"
  else
    echo "  FAIL: loop still running ${TIMEOUT}s after pg_terminate_backend"; fail=1; kill -9 "$bg" 2>/dev/null
  fi
else
  echo "  FAIL: could not observe the runaway backend as active"; fail=1; kill -9 "$bg" 2>/dev/null
fi

# ---- check 3: server healthy after both ----
alive="$(q 'SELECT 1')"
[ "$alive" = "1" ] && echo "check 3: ok: server healthy after cancel+terminate" || { echo "check 3: FAIL: server unhealthy"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "pljs-cancel-checks: FAIL" >&2
  exit 1
fi
echo "pljs-cancel-checks: OK - cancel and terminate both stop a runaway pljs loop"
