#!/usr/bin/env bash
# PLAN: memuat rencana peran security di atas skema 01–08 pada DB sementara, lalu menjalankan tes plan.
# TIDAK bagian dari tests/run.sh. Jalankan sebagai superuser.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; DB="${DB:-complex_plan}"
dropdb --if-exists "$DB" >/dev/null 2>&1; createdb "$DB"
DB="$DB" DEV=1 "$ROOT/scripts/migrate.sh" >/dev/null || { echo "MIGRASI GAGAL"; exit 2; }
psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f "$ROOT/db/plan/PLAN_10_security_role.sql" || { echo "PLAN SQL GAGAL DIMUAT"; exit 3; }
OUT="$(psql -d "$DB" -X -f "$ROOT/tests/plan/PLAN_security_test.sql" 2>&1)"
echo "$OUT" | grep -E '^(===|psql:.*(PASS|FAIL))' | sed -E 's/^psql:[^ ]+ (NOTICE|WARNING):  //; s/^psql:[^:]+:[0-9]+: //'
echo "$OUT" | grep -E 'ERROR|FATAL' | grep -v NOTICE | sed 's/^/!! /'
P=$(echo "$OUT" | grep -c 'NOTICE:  PASS'); F=$(echo "$OUT" | grep -c 'NOTICE:  FAIL'); E=$(echo "$OUT" | grep -cE '(^|: )ERROR')
echo "------------------------------------------------"; echo "PLAN  LULUS: $P   GAGAL: $F   ERROR-TAK-TERDUGA: $E"
[ "$F" -eq 0 ] && [ "$E" -eq 0 ]
