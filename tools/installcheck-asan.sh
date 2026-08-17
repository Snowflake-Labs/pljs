#!/usr/bin/env bash
#
# Run the pljs regression suite under AddressSanitizer.
#
# Why this starts its own postmaster instead of using `make installcheck`:
# PGXS's installcheck has no temp instance -- it runs against an already-running
# server.  Exporting the sanitizer environment around the make invocation
# therefore sanitizes pg_regress and psql, not the backend, and the backend is
# the only process that runs pljs.  So the sanitizer has to be in the
# postmaster's environment at startup, which means starting the postmaster here.
#
# The suite is heavier under ASan (expect several times the usual wall clock), and
# pg_cancellation / pg_object_keys_leak are the slow ones.
#
# Usage:
#   tools/installcheck-asan.sh                  # build, start, run, report
#   ASAN_KEEP=1 tools/installcheck-asan.sh      # leave the instance up afterwards
#   tools/installcheck-asan.sh pg_bytea_bytes   # a subset of tests
#
# Requires a PostgreSQL built with the same compiler family.  A stock package
# build works for leak-free checking of pljs itself, but note that
# detect_leaks=1 will also report allocations the server makes and never frees on
# purpose, which is why it is off by default here -- ASan's value for this
# extension is bounds and use-after-free, not leak counting.  Use
# tools/pljs-memory-matrix.sh for leaks.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PG_CONFIG="${PG_CONFIG:-pg_config}"

command -v "$PG_CONFIG" >/dev/null || { echo "asan: $PG_CONFIG not found" >&2; exit 2; }
BINDIR="$("$PG_CONFIG" --bindir)"
CC="$("$PG_CONFIG" --cc)"

DATA="${ASAN_DATA:-/tmp/pljs_asan_data}"
PORT="${ASAN_PORT:-55999}"
SOCK="${ASAN_SOCK:-/tmp/pljs_asan}"
LOG="${ASAN_LOG:-/tmp/pljs_asan_postmaster.log}"
ASAN_REPORT="${ASAN_REPORT:-/tmp/pljs_asan_report}"

# ---------------------------------------------------------------------------
# Locate the ASan runtime.  It has to be force-loaded into the postmaster,
# because the postmaster itself was not built with -fsanitize=address -- only
# pljs.so is, and a dlopen'd sanitized library cannot initialise the runtime
# on its own.
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin)
    PRELOAD_VAR=DYLD_INSERT_LIBRARIES
    RT="$($CC -print-file-name=libclang_rt.asan_osx_dynamic.dylib 2>/dev/null)"
    if [ ! -f "$RT" ]; then
      # Apple's clang ships it under the toolchain's lib/darwin.
      RT="$(dirname "$(xcrun -f clang 2>/dev/null)")/../lib/clang"
      RT="$(ls -d "$RT"/*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib 2>/dev/null | tail -1)"
    fi
    ;;
  *)
    PRELOAD_VAR=LD_PRELOAD
    RT="$($CC -print-file-name=libasan.so 2>/dev/null)"
    [ -f "$RT" ] || RT="$($CC -print-file-name=libclang_rt.asan-x86_64.so 2>/dev/null)"
    ;;
esac

if [ -z "${RT:-}" ] || [ ! -f "$RT" ]; then
  echo "asan: could not locate the ASan runtime for $CC" >&2
  echo "asan: on macOS install LLVM (brew install llvm) or use Xcode's clang" >&2
  exit 2
fi
echo "asan: runtime $RT"

# halt_on_error=0 keeps the suite going so one report does not hide the rest;
# every report still lands in $ASAN_REPORT.*.  detect_leaks is off: see above.
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=0:abort_on_error=0:print_stacktrace=1:log_path=$ASAN_REPORT:detect_stack_use_after_return=1:strict_string_checks=1"

# ---------------------------------------------------------------------------
# Build pljs with the sanitizer.
# ---------------------------------------------------------------------------
echo "asan: building"
ASAN_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1"
make -C "$ROOT" clean >/dev/null 2>&1
if ! make -C "$ROOT" \
      CFLAGS_SL="$ASAN_CFLAGS" \
      COPT="$ASAN_CFLAGS" \
      SHLIB_LINK_INTERNAL="$ASAN_CFLAGS" \
      > /tmp/pljs_asan_build.log 2>&1; then
  echo "asan: build failed; see /tmp/pljs_asan_build.log" >&2
  tail -20 /tmp/pljs_asan_build.log >&2
  exit 2
fi
make -C "$ROOT" install >/dev/null 2>&1 || { echo "asan: install failed" >&2; exit 2; }

# ---------------------------------------------------------------------------
# A dedicated instance, so a crash cannot take out anything that matters and the
# sanitizer environment is unambiguously the postmaster's.
# ---------------------------------------------------------------------------
if [ -d "$DATA" ]; then
  "$BINDIR/pg_ctl" -D "$DATA" -s stop -m immediate >/dev/null 2>&1
  rm -rf "$DATA"
fi
mkdir -p "$SOCK"
echo "asan: initdb $DATA"
"$BINDIR/initdb" -D "$DATA" -N >/tmp/pljs_asan_initdb.log 2>&1 || {
  echo "asan: initdb failed; see /tmp/pljs_asan_initdb.log" >&2; exit 2; }

echo "asan: starting postmaster with $PRELOAD_VAR set"
env "$PRELOAD_VAR=$RT" "$BINDIR/pg_ctl" -D "$DATA" -l "$LOG" \
    -o "-p $PORT -k $SOCK -c listen_addresses='' -c max_prepared_transactions=4" \
    -w -t 120 start >/dev/null 2>&1 || {
  echo "asan: postmaster failed to start; see $LOG" >&2; tail -30 "$LOG" >&2; exit 2; }

cleanup() {
  if [ "${ASAN_KEEP:-0}" = "1" ]; then
    echo "asan: instance left running on $SOCK port $PORT (ASAN_KEEP=1)"
  else
    "$BINDIR/pg_ctl" -D "$DATA" -s stop -m immediate >/dev/null 2>&1
  fi
}
trap cleanup EXIT

rm -f "$ASAN_REPORT".* 2>/dev/null

# ---------------------------------------------------------------------------
# Run the suite.  init-extension must lead: it is the only test that runs
# CREATE EXTENSION, so any test paired without it fails on its own.
# ---------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  TESTS="init-extension $*"
else
  TESTS=""
fi

echo "asan: running the suite"
if [ -n "$TESTS" ]; then
  PGHOST="$SOCK" PGPORT="$PORT" make -C "$ROOT" installcheck REGRESS="$TESTS" \
    > /tmp/pljs_asan_installcheck.log 2>&1
else
  PGHOST="$SOCK" PGPORT="$PORT" make -C "$ROOT" installcheck \
    > /tmp/pljs_asan_installcheck.log 2>&1
fi
suite_rc=$?

tail -5 /tmp/pljs_asan_installcheck.log

# ---------------------------------------------------------------------------
# Report.  A green suite with sanitizer reports is still a failure: the reports
# are the point.
# ---------------------------------------------------------------------------
reports=$(ls "$ASAN_REPORT".* 2>/dev/null | wc -l | tr -d ' ')
echo
if [ "$reports" != "0" ]; then
  echo "asan: FAIL $reports sanitizer report(s):"
  for f in "$ASAN_REPORT".*; do
    echo "--- $f"
    sed -n '1,25p' "$f"
  done
  exit 1
fi

# ASan writes to stderr, which for a backend is the server log, so check there
# too in case log_path did not take.
if grep -qaE 'AddressSanitizer|SUMMARY: .*Sanitizer' "$LOG"; then
  echo "asan: FAIL sanitizer output in the server log:"
  grep -aE -A15 'AddressSanitizer' "$LOG" | head -40
  exit 1
fi

if [ "$suite_rc" -ne 0 ]; then
  echo "asan: FAIL suite failed (no sanitizer report, so this is a plain test failure)"
  echo "asan: see /tmp/pljs_asan_installcheck.log and $ROOT/regression.diffs"
  exit 1
fi

echo "asan: OK suite passed with no sanitizer reports"
