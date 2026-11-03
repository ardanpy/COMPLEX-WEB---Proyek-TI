#!/usr/bin/env bash
# Setup database lokal COMPLEX dalam satu perintah.
#   ./scripts/setup_local.sh                 # DB 'complex' + akun uji (1 admin, 2 warga)
#   MODE=demo ./scripts/setup_local.sh       # + data demo lengkap
#   MODE=clean ./scripts/setup_local.sh      # skema + data awal saja (tanpa akun)
#   RESET=1 ./scripts/setup_local.sh         # HAPUS lalu buat ulang DB (data lokal hilang)
# Koneksi memakai variabel standar PostgreSQL: PGHOST PGPORT PGUSER PGPASSWORD (default: socket lokal).
# Butuh akun superuser (mis. postgres) karena membuat role & ekstensi.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${DB:-complex}"; MODE="${MODE:-accounts}"; ENVFILE="${ENVFILE:-$ROOT/.env.local}"

command -v psql >/dev/null || { echo "psql tidak ditemukan. Pasang PostgreSQL client 16+ (lihat docs/SETUP_LOCAL.md)."; exit 1; }
psql -X -d postgres -tAc "select 1" >/dev/null 2>&1 || { echo "Tidak bisa terhubung ke PostgreSQL. Cek PGHOST/PGPORT/PGUSER/PGPASSWORD dan pastikan server hidup."; exit 1; }
[ "$(psql -X -d postgres -tAc "select rolsuper from pg_roles where rolname=current_user")" = "t" ] || { echo "User koneksi harus superuser (mis. PGUSER=postgres)."; exit 1; }
VER=$(psql -X -d postgres -tAc "show server_version_num"); [ "$VER" -ge 150000 ] || { echo "PostgreSQL >= 15 diperlukan (disarankan 16). Versi terdeteksi: $VER"; exit 1; }

EXISTS=$(psql -X -d postgres -tAc "select 1 from pg_database where datname='$DB'")
if [ -n "$EXISTS" ]; then
  if [ "${RESET:-0}" = "1" ]; then dropdb --if-exists "$DB"; else echo "Database '$DB' sudah ada. Jalankan dengan RESET=1 untuk membuat ulang (data hilang)."; exit 1; fi
fi
createdb "$DB"
case "$MODE" in demo) DEVV=1;; accounts) DEVV=accounts;; clean) DEVV=0;; *) echo "MODE harus accounts|demo|clean"; exit 1;; esac
DB="$DB" DEV="$DEVV" "$ROOT/scripts/migrate.sh"

# password role aplikasi: acak, disimpan di .env.local (di-ignore git), tidak dicetak ke layar
APP_PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))' 2>/dev/null || openssl rand -base64 32 | tr -d '/+=\n')"
echo "ALTER ROLE complex_app WITH LOGIN PASSWORD :'pw'" | psql -X -d postgres -v ON_ERROR_STOP=1 -v pw="$APP_PW" >/dev/null
HOST="${PGHOST:-localhost}"; case "$HOST" in /*) HOST=localhost;; esac
umask 077
cat > "$ENVFILE" <<ENV
# Dibuat oleh scripts/setup_local.sh. JANGAN di-commit.
DATABASE_URL=postgresql://complex_app:${APP_PW}@${HOST}:${PGPORT:-5432}/${DB}
DB_NAME=${DB}
# Pepper HMAC untuk OTP: hanya di backend, BUKAN di DB. Ganti = semua OTP aktif tidak berlaku.
OTP_PEPPER=$(python3 -c 'import secrets;print(secrets.token_hex(32))' 2>/dev/null || openssl rand -hex 32)
ENV
grep -qxs ".env.local" "$ROOT/.gitignore" 2>/dev/null || echo ".env.local" >> "$ROOT/.gitignore" 2>/dev/null || true
echo
echo "Selesai. DB '$DB' siap (mode: $MODE). Konfigurasi backend ada di: $ENVFILE"
[ "$MODE" = "clean" ] || echo "Akun uji: lihat docs/SETUP_LOCAL.md (password uji hanya untuk lokal)."
