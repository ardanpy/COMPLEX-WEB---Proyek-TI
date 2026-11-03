#!/usr/bin/env bash
# DB segar (akun uji) -> login_sim.py. Jalankan sebagai superuser/OS user postgres.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export DB="${DB:-complex_login}"
dropdb --if-exists "$DB" >/dev/null 2>&1; createdb "$DB"
DEV=accounts "$ROOT/scripts/migrate.sh" >/dev/null || { echo "MIGRASI GAGAL"; exit 2; }
COMPLEX_TEST_DSN="dbname=$DB" python3 -I "$ROOT/tests/login_sim.py"
