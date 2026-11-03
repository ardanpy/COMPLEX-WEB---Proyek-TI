#!/usr/bin/env bash
# Memasang skema ke database kosong. Jalankan sebagai pemilik/superuser database.
#   DB=complex ./scripts/migrate.sh          # skema + data awal wajib
#   DB=complex DEV=1 ./scripts/migrate.sh    # + data demo (JANGAN di produksi)
set -euo pipefail
DB="${DB:-complex}"; DIR="$(cd "$(dirname "$0")/../db" && pwd)"
for f in 01_extensions_roles 02_schema 03_security 04_rls 05_seed; do
  echo ">> $f"; psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$DIR/$f.sql"
done
if [ "${DEV:-0}" = "1" ]; then echo ">> dev/06_demo_seed"; psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$DIR/dev/06_demo_seed.sql"; fi
echo "Selesai. Atur password role aplikasi:  ALTER ROLE complex_app WITH LOGIN PASSWORD '...';"
