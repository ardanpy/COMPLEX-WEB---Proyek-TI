#!/usr/bin/env bash
# Memasang skema ke database kosong. Jalankan sebagai pemilik/superuser database.
#   DB=complex ./scripts/migrate.sh          # skema + data awal wajib
#   DB=complex DEV=1 ./scripts/migrate.sh    # + data demo lengkap (JANGAN di produksi)
#   DB=complex PLAN=1 ./scripts/migrate.sh   # + rancangan peran security (PLAN, opsional)
#   DB=complex DEV=accounts ./scripts/migrate.sh   # + hanya 1 admin & 2 warga untuk uji login
set -euo pipefail
DB="${DB:-complex}"; DIR="$(cd "$(dirname "$0")/../db" && pwd)"
for f in 01_extensions_roles 02_schema 03_security 04_rls 05_seed 06_user_photo 07_auth_otp 08_guest_session 09_gap_fixes; do
  echo ">> $f"; psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$DIR/$f.sql"
done
if [ "${PLAN:-0}" = "1" ]; then echo ">> PLAN_10_security_role (RANCANGAN, belum final)"; psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$DIR/plan/PLAN_10_security_role.sql"; fi
if [ "${DEV:-0}" = "1" ]; then echo ">> dev/06_demo_seed"; psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$DIR/dev/06_demo_seed.sql"; fi
if [ "${DEV:-0}" = "accounts" ]; then echo ">> dev/accounts_min (1 admin + 2 warga)"; psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$DIR/dev/accounts_min.sql"; fi
echo "Selesai. Atur password role aplikasi:  ALTER ROLE complex_app WITH LOGIN PASSWORD '...';"
