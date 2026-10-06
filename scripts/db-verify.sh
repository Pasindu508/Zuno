#!/usr/bin/env bash
# =============================================================================
# db-verify.sh - verify the Zuno database on a throwaway PostgreSQL cluster.
#
#   1. initdb a fresh cluster (trust auth, 127.0.0.1 only, no unix socket)
#   2. apply supabase/tests/support/supabase_stubs.sql (roles, auth, storage,
#      extensions, realtime publication - a minimal stand-in for Supabase)
#   3. apply supabase/migrations/*.sql in order
#   4. apply supabase/seed.sql (and check it is in sync with zuno_seed.json)
#   5. apply supabase/tests/support/test_helpers.sql
#   6. run every supabase/tests/*.sql file and count PASS assertions
#
# This is vanilla PostgreSQL with Supabase stubs - NOT a hosted Supabase
# project. Environment:
#   PG_BIN             directory containing initdb, pg_ctl, postgres
#                      (default: directory of `postgres` on PATH)
#   ZUNO_VERIFY_DIR    working directory for the cluster (default: mktemp)
#   ZUNO_VERIFY_PORT   TCP port on 127.0.0.1 (default: 54329)
#   ZUNO_VERIFY_KEEP   1 = keep the cluster directory afterwards
#   USE_PSQL           1 = use $PG_BIN/psql (or psql on PATH) instead of the
#                      bundled stdlib-only client supabase/tests/support/pgwire.py
# Exit status: 0 when everything passed, 1 on any failure, 2 on setup errors.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPA="$ROOT/supabase"
PG_BIN="${PG_BIN:-}"
if [ -z "$PG_BIN" ]; then
  if command -v postgres >/dev/null 2>&1; then
    PG_BIN="$(dirname "$(command -v postgres)")"
  else
    echo "db-verify: set PG_BIN to a directory containing initdb, pg_ctl and postgres" >&2
    exit 2
  fi
fi
PORT="${ZUNO_VERIFY_PORT:-54329}"
KEEP="${ZUNO_VERIFY_KEEP:-0}"
DB="zuno_verify"

for bin in initdb pg_ctl postgres; do
  if [ ! -x "$PG_BIN/$bin" ]; then
    echo "db-verify: $PG_BIN/$bin not found or not executable" >&2
    exit 2
  fi
done
command -v python3 >/dev/null 2>&1 || { echo "db-verify: python3 is required" >&2; exit 2; }

CREATED_WORK=0
WORK="${ZUNO_VERIFY_DIR:-}"
if [ -z "$WORK" ]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/zuno-db-verify.XXXXXX")"
  CREATED_WORK=1
fi
mkdir -p "$WORK"
DATA="$WORK/cluster"
LOG="$WORK/postgres.log"
OUT="$WORK/output"
rm -rf "$DATA" "$OUT"
mkdir -p "$OUT"

PSQL=""
if [ "${USE_PSQL:-0}" = "1" ]; then
  if [ -x "$PG_BIN/psql" ]; then PSQL="$PG_BIN/psql"; elif command -v psql >/dev/null 2>&1; then PSQL="$(command -v psql)"; fi
  [ -n "$PSQL" ] || { echo "db-verify: USE_PSQL=1 but psql was not found" >&2; exit 2; }
fi

# run_sql <database> <file>  - prints notices/errors, returns non-zero on SQL error
run_sql() {
  if [ -n "$PSQL" ]; then
    "$PSQL" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres -d "$1" -f "$2" 2>&1
  else
    python3 "$SUPA/tests/support/pgwire.py" --host 127.0.0.1 --port "$PORT" --user postgres --dbname "$1" --no-rows -f "$2" 2>&1
  fi
}
run_cmd() {
  if [ -n "$PSQL" ]; then
    "$PSQL" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -U postgres -d "$1" -c "$2" 2>&1
  else
    python3 "$SUPA/tests/support/pgwire.py" --host 127.0.0.1 --port "$PORT" --user postgres --dbname "$1" --no-rows -c "$2" 2>&1
  fi
}

cleanup() {
  "$PG_BIN/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null 2>&1 || true
  if [ "$KEEP" != "1" ] && [ "$CREATED_WORK" = "1" ]; then
    rm -rf "$WORK"
  elif [ "$KEEP" != "1" ]; then
    rm -rf "$DATA"
  fi
}
trap cleanup EXIT

echo "== Zuno database verification (vanilla PostgreSQL + Supabase stubs)"
echo "   postgres: $("$PG_BIN/postgres" --version)"
echo "   client:   ${PSQL:-supabase/tests/support/pgwire.py}"
echo "   workdir:  $WORK"

"$PG_BIN/initdb" -D "$DATA" -U postgres --auth=trust --encoding=UTF8 --no-locale >"$WORK/initdb.log" 2>&1 \
  || { echo "initdb failed:"; cat "$WORK/initdb.log"; exit 2; }
"$PG_BIN/pg_ctl" -D "$DATA" -l "$LOG" -w -t 60 \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c timezone=UTC" \
  start >/dev/null || { echo "postgres failed to start:"; tail -20 "$LOG"; exit 2; }

run_cmd postgres "create database $DB" >/dev/null || { echo "create database failed"; exit 2; }

apply() {
  local file="$1" label="$2"
  if ! run_sql "$DB" "$file" >"$OUT/$(basename "$file").log"; then
    echo "   FAILED  $label"
    sed 's/^/           /' "$OUT/$(basename "$file").log" | grep -v 'NOTICE:  PASS' | tail -25
    exit 1
  fi
  echo "   applied $label"
}

echo "-- setup"
apply "$SUPA/tests/support/supabase_stubs.sql" "tests/support/supabase_stubs.sql"
migration_count=0
for migration in "$SUPA"/migrations/*.sql; do
  apply "$migration" "migrations/$(basename "$migration")"
  migration_count=$((migration_count + 1))
done
if python3 "$ROOT/scripts/generate-seed-sql.py" --check >/dev/null 2>&1; then
  echo "   seed.sql is in sync with supabase/seed/zuno_seed.json"
else
  echo "   FAILED  seed.sql is out of date - run python3 scripts/generate-seed-sql.py"
  exit 1
fi
apply "$SUPA/seed.sql" "seed.sql"
apply "$SUPA/tests/support/test_helpers.sql" "tests/support/test_helpers.sql"

echo "-- tests"
total_pass=0
failed_files=0
for test_file in "$SUPA"/tests/*.sql; do
  name="$(basename "$test_file")"
  log="$OUT/$name.log"
  if run_sql "$DB" "$test_file" >"$log"; then
    status="ok  "
  else
    status="FAIL"
    failed_files=$((failed_files + 1))
  fi
  passes="$(grep -c 'PASS:' "$log" || true)"
  total_pass=$((total_pass + passes))
  printf "   %s %-32s %4d assertions passed\n" "$status" "$name" "$passes"
  if [ "$status" = "FAIL" ]; then
    grep -v 'PASS:' "$log" | sed 's/^/           /' | tail -25
  fi
done

echo "-- summary"
echo "   migrations applied: $migration_count"
echo "   assertions passed:  $total_pass"
echo "   failing test files: $failed_files"
if [ "$failed_files" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
