#!/usr/bin/env bash
# Membangun DB uji dari nol (+demo seed), menjalankan test_schema.sql, ringkas hasil. Jalankan sebagai superuser.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; DB="${DB:-complex_test}"
dropdb --if-exists "$DB" >/dev/null 2>&1; createdb "$DB"
DB="$DB" DEV=1 "$ROOT/scripts/migrate.sh" >/dev/null || { echo "MIGRASI GAGAL"; exit 2; }
OUT="$(psql -d "$DB" -X -f "$ROOT/tests/test_schema.sql" 2>&1)"
echo "$OUT" | grep -E '^(===|psql:.*(PASS|FAIL))' | sed -E 's/^psql:[^ ]+ (NOTICE|WARNING):  //; s/^psql:[^:]+:[0-9]+: //'
echo "$OUT" | grep -E 'ERROR|FATAL' | grep -v 'NOTICE' | sed 's/^/!! /'
P=$(echo "$OUT" | grep -c 'NOTICE:  PASS'); F=$(echo "$OUT" | grep -c 'NOTICE:  FAIL'); E=$(echo "$OUT" | grep -cE '(^|: )ERROR')
echo "------------------------------------------------"; echo "LULUS: $P   GAGAL: $F   ERROR-TAK-TERDUGA: $E"
[ "$F" -eq 0 ] && [ "$E" -eq 0 ]
