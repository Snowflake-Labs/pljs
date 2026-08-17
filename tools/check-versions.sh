#!/usr/bin/env bash
#
# Build and run the suite against several PostgreSQL versions, plus the low-heap
# variant, and print one line per leg.
#
# Why this exists: the series is developed against one version, but pljs reaches
# into enough of the server (SPI, plancache, syscache, TupleDesc, the DDL path) that
# a version difference is a real risk rather than a formality.  A leg that fails here
# is a leg that would fail in CI on a machine nobody has looked at.
#
# Each leg gets its own instance on its own port and socket directory, so legs cannot
# collide with each other or with a development server.  The instances are started
# fresh and removed afterwards unless CV_KEEP=1.
#
# Usage:
#   tools/check-versions.sh                       # every pg_config found below
#   tools/check-versions.sh ~/pg/17/bin/pg_config # only the ones named
#   CV_KEEP=1 tools/check-versions.sh             # leave the instances up
#   CV_MEMORY_LIMIT=64 tools/check-versions.sh    # also run a low-heap leg
#
# The memory-limit leg matters because pljs.memory_limit changes which failures are
# reachable: a QuickJS-accounted leak that is a slow trend at the default becomes a
# hard "out of memory" error at 64MB, and several tests assert on error text that
# only appears under a low limit.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Candidate installations, in ascending version order.  Anything absent is skipped
# with a note rather than failing the run -- not every machine has every version.
if [ "$#" -gt 0 ]; then
  CANDIDATES=("$@")
else
  CANDIDATES=(
    "$HOME/pg-install/pg16/bin/pg_config"
    "$HOME/pg-install/pg17/bin/pg_config"
    "$HOME/pg-install/pg18/bin/pg_config"
  )
fi

BASE_PORT="${CV_BASE_PORT:-55700}"
RESULTS=()
overall=0

run_leg() {
  local pgc="$1" memlimit="${2:-}"
  local label ver bindir data sock port log rc leg

  if [ ! -x "$pgc" ]; then
    RESULTS+=("SKIP  $pgc (not installed)")
    return 0
  fi

  ver="$("$pgc" --version | awk '{print $2}')"
  bindir="$("$pgc" --bindir)"
  leg="pg${ver%%.*}"
  label="PostgreSQL $ver"
  [ -n "$memlimit" ] && { leg="${leg}_mem${memlimit}"; label="$label (pljs.memory_limit=${memlimit}MB)"; }

  data="/tmp/pljs_cv_${leg}"
  sock="/tmp/pljs_cv_sock_${leg}"
  log="/tmp/pljs_cv_${leg}.log"
  port=$((BASE_PORT++))

  echo
  echo "═══ $label ═══"

  # Build against this version.  A clean is required: object files from another
  # major version link but misbehave, which is a confusing way to discover that
  # PG_CONFIG changed.
  echo "  building"
  make -C "$ROOT" clean >/dev/null 2>&1
  if ! make -C "$ROOT" PG_CONFIG="$pgc" >"/tmp/pljs_cv_build_${leg}.log" 2>&1; then
    echo "  BUILD FAILED -- see /tmp/pljs_cv_build_${leg}.log"
    tail -15 "/tmp/pljs_cv_build_${leg}.log" | sed 's/^/    /'
    RESULTS+=("FAIL  $label -- build")
    overall=1
    return 0
  fi
  make -C "$ROOT" PG_CONFIG="$pgc" install >/dev/null 2>&1 || {
    echo "  INSTALL FAILED"; RESULTS+=("FAIL  $label -- install"); overall=1; return 0; }

  # Fresh instance.
  rm -rf "$data"; mkdir -p "$sock"
  echo "  initdb"
  "$bindir/initdb" -D "$data" -N >"/tmp/pljs_cv_initdb_${leg}.log" 2>&1 || {
    echo "  INITDB FAILED"; RESULTS+=("FAIL  $label -- initdb"); overall=1; return 0; }

  local opts=(-c "listen_addresses=" -c "max_prepared_transactions=4")
  # shared_preload_libraries is not required for pljs, but the memory limit has to be
  # set before the runtime is created, and _PG_init reads it at first use -- so it
  # goes in the server config rather than a per-session SET.
  [ -n "$memlimit" ] && opts+=(-c "pljs.memory_limit=$memlimit")

  echo "  starting on port $port"
  "$bindir/postgres" -D "$data" -p "$port" -k "$sock" "${opts[@]}" >"$log" 2>&1 &
  local pm=$!
  local ready=0
  for _ in $(seq 1 90); do
    "$bindir/pg_isready" -h "$sock" -p "$port" >/dev/null 2>&1 && { ready=1; break; }
    kill -0 "$pm" 2>/dev/null || break
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "  POSTMASTER DID NOT START -- see $log"
    tail -15 "$log" | sed 's/^/    /'
    RESULTS+=("FAIL  $label -- postmaster")
    overall=1
    kill "$pm" 2>/dev/null
    return 0
  fi

  # pljs.memory_limit is a custom GUC, so it is only accepted once the library is
  # known.  Report what the server actually ended up with rather than assuming.
  if [ -n "$memlimit" ]; then
    local got
    got=$(PGHOST="$sock" PGPORT="$port" "$bindir/psql" -X -qAt \
            -c "SHOW pljs.memory_limit" postgres 2>/dev/null)
    echo "  pljs.memory_limit reported as: ${got:-<unset>}"
  fi

  echo "  installcheck"
  PGHOST="$sock" PGPORT="$port" make -C "$ROOT" PG_CONFIG="$pgc" installcheck \
    >"/tmp/pljs_cv_check_${leg}.log" 2>&1
  rc=$?

  local summary
  summary=$(grep -aE '^# (All|[0-9]+ of)' "/tmp/pljs_cv_check_${leg}.log" | tail -1)
  echo "  ${summary:-no summary line}"

  if [ "$rc" -ne 0 ]; then
    grep -aE '^not ok' "/tmp/pljs_cv_check_${leg}.log" | sed 's/^/    /' | head -20
    RESULTS+=("FAIL  $label -- ${summary:-installcheck}")
    overall=1
  else
    RESULTS+=("ok    $label -- ${summary#\# }")
  fi

  # A crash anywhere in the run is a failure even if pg_regress was satisfied.
  if grep -qaE 'was terminated by signal|server process .* exited with' "$log"; then
    echo "  CRASH in the server log:"
    grep -aE 'was terminated by signal|server process .* exited with' "$log" | head -5 | sed 's/^/    /'
    RESULTS+=("FAIL  $label -- backend crash in server log")
    overall=1
  fi

  if [ "${CV_KEEP:-0}" = "1" ]; then
    echo "  instance left running on $sock port $port (CV_KEEP=1)"
  else
    kill "$pm" 2>/dev/null; wait "$pm" 2>/dev/null
    rm -rf "$data" "$sock"
  fi
}

for pgc in "${CANDIDATES[@]}"; do
  run_leg "$pgc"
done

if [ -n "${CV_MEMORY_LIMIT:-}" ]; then
  # One version is enough for the low-heap leg: it exercises pljs's own limit
  # handling, which does not vary by server version.
  for pgc in "${CANDIDATES[@]}"; do
    [ -x "$pgc" ] || continue
    run_leg "$pgc" "$CV_MEMORY_LIMIT"
    break
  done
fi

echo
echo "═══ summary ═══"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo
if [ "$overall" -ne 0 ]; then
  echo "check-versions: FAIL"
  exit 1
fi
echo "check-versions: OK"
