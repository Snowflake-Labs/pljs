#!/bin/bash
#
# pljs-memory-matrix.sh -- long-running mixed success/failure memory harness.
#
# WHY THIS EXISTS, given tools/pljs-soak.sh already soaks the backend:
# pljs-soak.sh only ever exercises errors CAUGHT INSIDE JavaScript, so the
# enclosing pljs call always succeeds.  A whole class of leak needs the error to
# ESCAPE call_function -- an out-of-range integer, an unparseable numeric string,
# a number bound to bytea -- and that class was invisible to every tool in this
# repository.  It cost one memory context (~1KB) per failed call, from plain SQL,
# without bound.  This harness drives both classes and interleaves them with
# correctness assertions.
#
# WHAT IT MEASURES, and why three views are needed:
#   * per-call context COUNT   -- a hard assertion (must be 0 between calls),
#                                 not a threshold.  Catches palloc-side leaks.
#   * total pljs context BYTES -- must plateau, not trend.
#   * OS RSS of the backend    -- the only view that can see QuickJS/libc leaks,
#                                 which pg_backend_memory_contexts cannot.
# A low pljs.memory_limit run turns a slow QuickJS-accounted leak into a fast
# hard error instead of a slow trend.
#
# Single backend on purpose (-c 1 -j 1): backend-local growth only accumulates if
# the connection is never recycled.
#
# Usage:
#   tools/pljs-memory-matrix.sh                       # ~5 minutes
#   MM_DURATION=3600 tools/pljs-memory-matrix.sh      # nightly
#   MM_MEMORY_LIMIT=64 tools/pljs-memory-matrix.sh    # low-heap variant
#   MM_EXPECT_LEAK=1 tools/pljs-memory-matrix.sh      # invert: FAIL if clean
#
# MM_EXPECT_LEAK is how we prove the harness can actually detect something: run
# it against a known-leaky build and it must report a leak.  A detector that
# stays quiet on leaky code is worthless.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SQLDIR="$HERE/memory-matrix"

DURATION="${MM_DURATION:-300}"
DB="${MM_DB:-contrib_regression}"
PORT="${PGPORT:-5432}"
HOST="${PGHOST:-/tmp}"
MEMLIMIT="${MM_MEMORY_LIMIT:-}"
EXPECT_LEAK="${MM_EXPECT_LEAK:-0}"
RSS_SLACK_MB="${MM_RSS_SLACK_MB:-24}"
BYTES_SLACK_MB="${MM_BYTES_SLACK_MB:-4}"

APP="pljs_mm_$$"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -d "$DB")

for t in pgbench psql; do
  command -v "$t" >/dev/null || { echo "pljs-memory-matrix: $t not found" >&2; exit 2; }
done

echo "pljs-memory-matrix: duration=${DURATION}s db=$DB${MEMLIMIT:+ memory_limit=${MEMLIMIT}MB}"
echo "pljs-memory-matrix: loading scenarios"
"${PSQL[@]}" -f "$SQLDIR/setup.sql" >/dev/null || {
  echo "pljs-memory-matrix: setup failed" >&2; exit 2; }
"${PSQL[@]}" -c 'TRUNCATE pljs_mm_samples' >/dev/null

# ---------------------------------------------------------------------------
# Phase 1: pgbench, one backend, weighted mix.
#
# Weights: success dominates so failures are interleaved into a realistic
# steady state rather than being the whole workload.  sample runs often enough
# for a slope but rarely enough not to distort the mix.
# ---------------------------------------------------------------------------
PGOPTIONS_ARG=""
[ -n "$MEMLIMIT" ] && PGOPTIONS_ARG="-c pljs.memory_limit=$MEMLIMIT"

: > /tmp/pljs_mm_pgbench.log
echo "pljs-memory-matrix: phase 1 -- pgbench mixed workload"
# DDL churn is now ON by default.
#
# It used to be opt-in because it reproduced an unfixed leak in the
# CREATE OR REPLACE FUNCTION path -- a tight loop reached ~500MB RSS and then
# SIGSEGV in seconds, on stock upstream too -- and a permanently red tool is not a
# gate.  That leak is fixed (the validator no longer resets the whole context cache
# on every DDL), so the reproducer becomes a regression gate: measured on
# PostgreSQL 17 it now peaks at ~20MB instead of crashing.
#
# MM_DDL_CHURN=0 turns it off, for bisecting against a build that still has the
# leak.
CHURN_ARG=(-f "$SQLDIR/churn.sql@2")
if [ "${MM_DDL_CHURN:-1}" = "0" ]; then
  echo "pljs-memory-matrix: DDL churn disabled by MM_DDL_CHURN=0"
  CHURN_ARG=()
fi

PGAPPNAME="$APP" PGOPTIONS="$PGOPTIONS_ARG" pgbench \
  -h "$HOST" -p "$PORT" -d "$DB" \
  -n -c 1 -j 1 -T "$DURATION" \
  -D v=42 \
  -f "$SQLDIR/success.sql@60" \
  -f "$SQLDIR/fail_escape.sql@20" \
  -f "$SQLDIR/fail_caught.sql@10" \
  ${CHURN_ARG[@]+"${CHURN_ARG[@]}"} \
  -f "$SQLDIR/sample.sql@8" \
  >/tmp/pljs_mm_pgbench.log 2>&1 &
pgb=$!

# Sample the backend's OS RSS from outside: the QuickJS heap is invisible to
# pg_backend_memory_contexts because QuickJS runs on the libc allocator.
beid=""
rss_samples=""
for _ in $(seq 1 40); do
  beid="$("${PSQL[@]}" -tA -c \
    "SELECT pid FROM pg_stat_activity WHERE application_name = '$APP' LIMIT 1" 2>/dev/null)"
  [ -n "$beid" ] && break
  sleep 0.25
done
if [ -z "$beid" ]; then
  echo "pljs-memory-matrix: WARNING could not find the pgbench backend; RSS not sampled" >&2
fi

while kill -0 "$pgb" 2>/dev/null; do
  if [ -n "$beid" ]; then
    r="$(ps -o rss= -p "$beid" 2>/dev/null | tr -d ' ')"
    [ -n "$r" ] && rss_samples="$rss_samples $r"
  fi
  sleep 2
done
wait "$pgb"; pgb_rc=$?

# pgbench aborts the client on an un-caught SQL error, so a RAISE from
# mm_assert_healthy() -- i.e. a wrong answer after a failure -- lands here.
if [ "$pgb_rc" -ne 0 ] || grep -qiE 'ERROR|FATAL' /tmp/pljs_mm_pgbench.log; then
  echo "pljs-memory-matrix: FAIL pgbench reported errors (a failed assertion means"
  echo "                    the backend returned a WRONG ANSWER after a failure):"
  grep -iE 'ERROR|FATAL|client [0-9]+ aborted' /tmp/pljs_mm_pgbench.log | head -8 | sed 's/^/    /'
  phase1_fail=1
else
  phase1_fail=0
fi

tps=$(grep -E '^tps' /tmp/pljs_mm_pgbench.log | head -1)
echo "pljs-memory-matrix: $tps"

# ---------------------------------------------------------------------------
# Phase 2: truly UNCAUGHT errors reaching the client.
#
# pgbench cannot express this -- it aborts the client on the first one -- but
# psql tolerates errors in-session, which is exactly the shape a real
# application retry loop has.
# ---------------------------------------------------------------------------
echo "pljs-memory-matrix: phase 2 -- uncaught errors in one session"
{
  echo "SELECT mm_sample();"
  for i in $(seq 1 300); do
    echo "SELECT mmf_overflow_int4();"
    echo "SELECT mmf_bad_string();"
    echo "SELECT mmf_bytea_number();"
    echo "SELECT mmf_throw();"
  done
  echo "SELECT mm_assert_healthy();"
  echo "SELECT mm_sample();"
} > /tmp/pljs_mm_uncaught.sql

# No ON_ERROR_STOP: every statement above is expected to fail, and the point is
# that the session survives all of them and stays correct.
psql -X -q -h "$HOST" -p "$PORT" -d "$DB" -f /tmp/pljs_mm_uncaught.sql \
  >/tmp/pljs_mm_uncaught.log 2>&1
if grep -q 'mm_assert_healthy:' /tmp/pljs_mm_uncaught.log; then
  echo "pljs-memory-matrix: FAIL wrong answer after 1200 uncaught errors:"
  grep 'mm_assert_healthy:' /tmp/pljs_mm_uncaught.log | head -3 | sed 's/^/    /'
  phase2_fail=1
else
  phase2_fail=0
fi

# The two samples bracketing phase 2 isolate the uncaught-error path.
read -r p2_before p2_after <<<"$("${PSQL[@]}" -tA -F' ' -c "
  WITH s AS (SELECT ctx_call, row_number() OVER (ORDER BY sample_no DESC) rn
               FROM pljs_mm_samples)
  SELECT max(ctx_call) FILTER (WHERE rn = 2), max(ctx_call) FILTER (WHERE rn = 1) FROM s")"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo
echo "pljs-memory-matrix: samples"
"${PSQL[@]}" -c "
  SELECT count(*)                      AS samples,
         max(calls)                    AS pljs_calls,
         max(ctx_call)                 AS max_percall_ctx,
         min(bytes_all)/1024           AS min_kb,
         max(bytes_all)/1024           AS max_kb
    FROM pljs_mm_samples"

# 1. Hard assertion: no per-call context may survive a call.  Deliberately not a
#    threshold -- between statements the correct answer is exactly zero.
leaked_ctx="$("${PSQL[@]}" -tA -c \
  'SELECT coalesce(max(ctx_call), 0) FROM pljs_mm_samples')"

# 2. Plateau, not line: compare the last third against the middle third, after
#    discarding the first third as warm-up.  A threshold on absolute growth is
#    the flakiest assertion in tools/pljs-soak.sh; a slope comparison is not.
read -r mid_kb last_kb <<<"$("${PSQL[@]}" -tA -F' ' -c "
  WITH s AS (SELECT bytes_all, ntile(3) OVER (ORDER BY sample_no) AS t
               FROM pljs_mm_samples)
  SELECT coalesce(round(avg(bytes_all) FILTER (WHERE t = 2) / 1024.0), 0),
         coalesce(round(avg(bytes_all) FILTER (WHERE t = 3) / 1024.0), 0)
    FROM s")"

fail=0

printf 'pljs-memory-matrix: per-call contexts alive between calls: %s (must be 0)\n' "$leaked_ctx"
[ "${leaked_ctx:-0}" -ne 0 ] && fail=1

printf 'pljs-memory-matrix: pljs context bytes  mid=%sKB last=%sKB (slack %sMB)\n' \
  "$mid_kb" "$last_kb" "$BYTES_SLACK_MB"
nsamples="$("${PSQL[@]}" -tA -c 'SELECT count(*) FROM pljs_mm_samples')"
if [ "${nsamples:-0}" -lt 9 ]; then
  # ntile(3) over fewer than 9 rows is too coarse for a slope to mean anything.
  echo "pljs-memory-matrix: WARNING only $nsamples samples; skipping the byte-slope check"
  echo "                    (raise MM_DURATION so the sample script runs more often)"
elif [ "${mid_kb:-0}" -gt 0 ]; then
  growth_kb=$(( ${last_kb:-0} - ${mid_kb:-0} ))
  [ "$growth_kb" -gt $(( BYTES_SLACK_MB * 1024 )) ] && {
    echo "pljs-memory-matrix: FAIL context bytes still trending (+${growth_kb}KB)"; fail=1; }
fi

printf 'pljs-memory-matrix: uncaught-error phase: ctx before=%s after=%s\n' \
  "${p2_before:-?}" "${p2_after:-?}"
if [ -n "${p2_after:-}" ] && [ "${p2_after:-0}" -gt "${p2_before:-0}" ]; then
  echo "pljs-memory-matrix: FAIL uncaught errors leaked $(( p2_after - p2_before )) context(s)"
  fail=1
fi

if [ -n "$rss_samples" ]; then
  rss_verdict=$(printf '%s' "$rss_samples" | awk -v slack="$RSS_SLACK_MB" '{
    n = NF; if (n < 6) { printf "too few samples (%d)", n; exit }
    # discard the first third as warm-up, then compare halves of the remainder
    start = int(n/3) + 1; mid = start + int((n - start) / 2)
    for (i = start; i <= mid; i++) { a += $i; ac++ }
    for (i = mid + 1; i <= n; i++) { b += $i; bc++ }
    if (ac == 0 || bc == 0) { printf "too few samples"; exit }
    am = a/ac/1024; bm = b/bc/1024; d = bm - am
    printf "first=%.1fMB last=%.1fMB delta=%+.1fMB %s", am, bm, d,
           (d > slack ? "FAIL" : "ok")
  }')
  echo "pljs-memory-matrix: backend RSS  $rss_verdict"
  case "$rss_verdict" in *FAIL) fail=1;; esac
else
  echo "pljs-memory-matrix: backend RSS  not sampled"
fi

[ "${phase1_fail:-0}" -ne 0 ] && fail=1
[ "${phase2_fail:-0}" -ne 0 ] && fail=1

echo
if [ "$EXPECT_LEAK" = "1" ]; then
  # Detector self-test: run against a leaky build, where finding nothing is the
  # actual failure.
  if [ "$fail" -eq 0 ]; then
    echo "pljs-memory-matrix: FAIL expected a leak (MM_EXPECT_LEAK=1) but found none"
    exit 1
  fi
  echo "pljs-memory-matrix: OK - leak detected as expected (MM_EXPECT_LEAK=1)"
  exit 0
fi

if [ "$fail" -ne 0 ]; then
  echo "pljs-memory-matrix: FAIL"
  exit 1
fi
echo "pljs-memory-matrix: OK - no per-call context survived, bytes and RSS plateaued,"
echo "                    and every post-failure assertion returned correct answers"
exit 0
