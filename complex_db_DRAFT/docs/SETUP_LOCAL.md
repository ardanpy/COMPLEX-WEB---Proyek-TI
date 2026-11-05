# Setup Database Lokal (PostgreSQL)

Tujuan: tiap anggota tim backend punya DB lokal identik, siap dipakai, dalam beberapa menit.
Kebutuhan: **PostgreSQL 16** (minimal 15), `psql`, dan Python 3 (untuk hash Argon2id & password acak).

## 1. Pasang PostgreSQL (pilih satu)

**A. Docker (paling cepat, tidak mengotori sistem)**
```bash
docker compose up -d            # memakai docker-compose.yml di root proyek
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres
```
Perlu klien `psql` di mesin Anda (lihat B, cukup bagian klien).

**B. Pasang langsung**
| OS | Perintah |
|---|---|
| Ubuntu/Debian | `sudo apt install postgresql-16 postgresql-client-16` |
| macOS (Homebrew) | `brew install postgresql@16 && brew services start postgresql@16` |
| Windows | pasang installer EnterpriseDB (catat password `postgres`), tambahkan `...\PostgreSQL\16\bin` ke PATH, jalankan skrip lewat **Git Bash** atau **WSL** |

Ubuntu: skrip dijalankan sebagai user `postgres`: `sudo -u postgres ./scripts/setup_local.sh`
(atau buat role superuser untuk diri sendiri: `sudo -u postgres createuser -s $USER`).

## 2. Jalankan setup (satu perintah)
```bash
pip install argon2-cffi          # hanya dibutuhkan untuk create_admin.sh & tes simulasi
./scripts/setup_local.sh         # DB "complex" + 1 admin + 2 warga untuk uji
```
Variasi:
| Perintah | Hasil |
|---|---|
| `MODE=demo ./scripts/setup_local.sh` | + data demo lengkap (pengumuman, laporan, dsb.) |
| `MODE=clean ./scripts/setup_local.sh` | hanya skema + blok Jati 1–7 + slot petugas (tanpa akun) |
| `RESET=1 ./scripts/setup_local.sh` | hapus & buat ulang DB (**data lokal hilang**) |
| `DB=complex_dev ./scripts/setup_local.sh` | nama DB lain |

Skrip akan: memeriksa koneksi, hak superuser, dan versi → membuat DB → menjalankan migrasi 01–07 → mengatur password role `complex_app` (acak) → menulis **`.env.local`** (izin 600, sudah di `.gitignore`) berisi `DATABASE_URL` dan `OTP_PEPPER` untuk backend. Skrip menolak menimpa DB yang sudah ada tanpa `RESET=1`.

## 3. Akun uji (hanya lokal)
Password semua akun: `Complex#Test2026`

| Email | Role | Kondisi | Untuk menguji |
|---|---|---|---|
| admin@complex.test | admin | aktif | login admin |
| budi@complex.test | warga (Jati 1/52) | aktif | login normal, lupa password |
| sari@complex.test | warga (Jati 2/15) | **belum aktif** | login pertama → OTP → set password |

Karena email belum terhubung, saat mengembangkan backend cetak kode OTP ke log konsol (hanya di mode dev), jangan pernah di produksi.

Tamu tidak punya akun: cukup membuka sesi tamu (lihat `docs/ROLES_AND_HOME.md` bagian 4); tidak ada akun uji untuk tamu.

## 4. Hubungkan backend
Baca `.env.local`:
```
DATABASE_URL=postgresql://complex_app:<acak>@localhost:5432/complex
OTP_PEPPER=<hex 64 karakter>
```
Backend **hanya** boleh memakai `complex_app` (bukan `postgres`). Sebelum tiap request yang butuh RLS, set konteks pengguna pada transaksi yang sama:
```sql
SELECT set_config('app.user_id', '<uuid-dari-sesi>', true), set_config('app.ip', '<ip>', true);
```
(`true` = berlaku hanya dalam transaksi; wajib dipakai dengan connection pool agar tidak bocor antar request.)

## 5. Verifikasi
```bash
sudo -u postgres tests/run.sh        # 195 asersi SQL (DB sementara complex_test)
sudo -u postgres tests/run_sim.sh    # 55 asersi alur login/OTP (DB sementara complex_login)
psql "$DATABASE_URL" -c "select current_user"   # harus: complex_app
```
Kedua tes membuat dan menimpa DB mereka sendiri, DB `complex` Anda tidak tersentuh. Detail lengkap: `docs/TESTING.md`.

## 6. Admin sungguhan (bukan akun uji)
```bash
ADMIN_EMAIL=ketua@contoh.id ADMIN_NAME="Ketua RT" DB=complex ./scripts/create_admin.sh
```
Untuk produksi: pakai `MODE=clean`, jangan pernah memuat akun/data demo.

## 7. Masalah umum
| Gejala | Penyebab / solusi |
|---|---|
| `Tidak bisa terhubung ke PostgreSQL` | server mati (`pg_ctlcluster 16 main start` / `brew services start postgresql@16` / `docker compose up -d`), atau PGHOST/PGUSER/PGPASSWORD belum diset |
| `User koneksi harus superuser` | jalankan sebagai `postgres` atau `createuser -s` untuk user Anda |
| `permission denied to create extension` | bukan superuser; `pgcrypto` & `btree_gist` butuh superuser |
| `Database ... sudah ada` | tambahkan `RESET=1` (menghapus data) atau ganti `DB=` |
| `role "complex_app" already exists` pada DB kedua | normal: role bersifat per-cluster; skrip idempoten |
| `password authentication failed for complex_app` | `.env.local` lama setelah RESET; jalankan ulang setup agar password sinkron |
| Windows: `bash\r` error | simpan skrip dengan akhir baris LF (`git config core.autocrlf input`) |
| Port 5432 bentrok dengan PostgreSQL lain | ubah mapping di `docker-compose.yml` (mis. `"127.0.0.1:5433:5432"`) dan set `PGPORT=5433` |

## 8. Hapus semuanya
```bash
dropdb complex ; psql -d postgres -c "DROP ROLE complex_app"   # DB lokal
docker compose down -v                                          # jika pakai Docker (hapus volume)
```
