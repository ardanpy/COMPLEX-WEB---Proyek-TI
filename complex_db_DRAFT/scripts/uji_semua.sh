#!/usr/bin/env bash
# Satu perintah: nyalakan PostgreSQL (Docker) -> siapkan Python -> jalankan 3 rangkaian tes -> simpan hasil.
# Bisa dijalankan dari terminal (./scripts/uji_semua.sh) atau klik dua kali "Jalankan-Tes-COMPLEX.desktop".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
OUT="$ROOT/hasil-tes"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
tahan() { echo; read -rp "Tekan Enter untuk menutup..." _ || true; }
gagal() { echo; echo "✗ $*"; tahan; exit 1; }

echo "== 1/4 Memeriksa alat =="
for c in docker psql python3; do
  command -v "$c" >/dev/null || gagal "'$c' belum terpasang. Jalankan: sudo pacman -S docker docker-compose postgresql python"
done
docker info >/dev/null 2>&1 || gagal "Docker belum aktif atau user belum di grup docker. Jalankan: sudo systemctl enable --now docker && sudo usermod -aG docker \$USER (lalu logout/login)."

echo "== 2/4 Menyalakan PostgreSQL 16 (Docker) =="
docker compose up -d --wait >/dev/null 2>&1 || docker compose up -d || gagal "Gagal menyalakan container database."
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres
for i in $(seq 1 30); do pg_isready -q && break; sleep 1; done
pg_isready -q || gagal "Database belum siap di localhost:5432 (apakah port 5432 dipakai PostgreSQL lain?)."

echo "== 3/4 Menyiapkan Python (venv .venv) =="
if [ ! -x .venv/bin/python ]; then python3 -m venv .venv || gagal "Gagal membuat venv."; fi
.venv/bin/pip install -q -r requirements-dev.txt || gagal "Gagal memasang pustaka Python (cek koneksi internet)."
export PATH="$ROOT/.venv/bin:$PATH"

echo "== 4/4 Menjalankan tes =="
declare -A RINGKAS; LULUS_SEMUA=1
jalankan() {   # nama, perintah
  local nama="$1" cmd="$2" f="$OUT/$STAMP-$1.txt"
  echo; echo "---- $nama ----"
  bash -c "$cmd" 2>&1 | tee "$f"; local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then RINGKAS[$nama]="LULUS"; else RINGKAS[$nama]="GAGAL (lihat $f)"; LULUS_SEMUA=0; fi
}
jalankan skema   "./tests/run.sh"
jalankan login   "./tests/run_sim.sh"
jalankan security "./tests/run_security.sh"

echo; echo "================ RINGKASAN ================"
for n in skema login security; do printf "%-10s %s\n" "$n" "${RINGKAS[$n]}"; done
echo "Hasil lengkap tersimpan di: $OUT/"
grep -hE "FAIL|^!!" "$OUT/$STAMP-"*.txt > "$OUT/$STAMP-BARIS-GAGAL.txt" 2>/dev/null
if [ -s "$OUT/$STAMP-BARIS-GAGAL.txt" ]; then echo "Baris bermasalah dikumpulkan di: $OUT/$STAMP-BARIS-GAGAL.txt  (kirim file ini ke pembuat backend)"; else rm -f "$OUT/$STAMP-BARIS-GAGAL.txt"; fi
command -v notify-send >/dev/null && notify-send "Tes COMPLEX" "$([ $LULUS_SEMUA = 1 ] && echo 'Semua tes LULUS' || echo 'Ada tes GAGAL, lihat terminal')"
tahan
[ "$LULUS_SEMUA" = 1 ]
