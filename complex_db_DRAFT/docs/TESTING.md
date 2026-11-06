# Menjalankan Tes di Lokal

Ada dua rangkaian tes. Keduanya **membangun database sementara sendiri** dari nol, jadi database kerja Anda (`complex`) tidak tersentuh.

| Tes | Perintah | Isi | Hasil yang diharapkan |
|---|---|---|---|
| Skema & keamanan (SQL) | `tests/run.sh` | 214 asersi langsung di PostgreSQL | `LULUS: 214   GAGAL: 0   ERROR-TAK-TERDUGA: 0` |
| Alur login backend (Python) | `tests/run_sim.sh` | 55 asersi: login, OTP, lupa password, tamu anonim, beranda per peran, injeksi, hak akses | `LULUS 55 / 55` |

## 1. Prasyarat
1. PostgreSQL 16 berjalan (lihat `docs/SETUP_LOCAL.md` bagian 1).
2. Akses **superuser** (tes membuat/menghapus DB dan role). Untuk Docker: `export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres`.
3. Hanya untuk simulasi login, pustaka Python:
```bash
pip install -r requirements-dev.txt      # psycopg[binary], argon2-cffi
```
Jika memakai `sudo -u postgres` (instalasi langsung di Linux), pustaka harus terpasang untuk Python yang dipakai user itu (`sudo pip install -r requirements-dev.txt`, tambahkan `--break-system-packages` jika diminta).

## 2. Tes skema & keamanan (SQL)
```bash
# Docker / user Anda sudah superuser:
./tests/run.sh
# Ubuntu, PostgreSQL terpasang langsung:
sudo -u postgres ./tests/run.sh
```
Yang terjadi: `dropdb/createdb complex_test` → migrasi 01–07 + data demo (`DEV=1`) → `tests/test_schema.sql` → ringkasan. Setiap baris `PASS`/`FAIL` dicetak, bagian dipisah `=== X. ... ===`.

| Bagian | Yang diuji |
|---|---|
| A | constraint & trigger guard (role, admin terakhir, format email/hash, dll.) |
| B | validasi fasilitas & anti-bentrok jadwal |
| C | laporan, notifikasi otomatis, SIGAP, lockout login |
| D | audit append-only, tidak membocorkan hash password |
| E | payload SQL injection diperlakukan sebagai data (query terparameter) |
| F | hak akses minimal role `complex_app` |
| G | RLS: isolasi data antar warga |
| H | login pra-autentikasi sebagai aplikasi |
| J | OTP: kedaluwarsa, 5 salah → terkunci, replay tiket, batas per jam, reset oleh admin |
| K | tamu tanpa akun: sesi anonim, hanya lewat fungsi, berita komplek saja, Lapor Tamu 24 jam, anti-spam, isolasi, notifikasi, kedaluwarsa & purge, beranda per peran |
| I | anonimisasi data pribadi |

Opsi: `DB=nama_lain ./tests/run.sh` untuk nama DB sementara berbeda. Kode keluar `0` bila semua lulus (cocok untuk CI).

## 3. Simulasi alur login backend (Python)
```bash
./tests/run_sim.sh                       # atau: sudo -u postgres ./tests/run_sim.sh
```
Yang terjadi: DB baru `complex_login` + akun uji (`DEV=accounts`) → `tests/login_sim.py` menjalankan alur seperti backend sungguhan (Argon2id, sesi, OTP dengan "outbox" email palsu, HMAC pepper acak per jalan) dengan role `complex_app`.

Catatan penting:
- Simulasi **mengubah data** (mis. budi ganti password). Karena itu `run_sim.sh` selalu membuat DB baru. Jangan jalankan `login_sim.py` langsung dua kali pada DB yang sama.
- DSN dapat diganti: `COMPLEX_TEST_DSN="dbname=... host=..." python3 -I tests/login_sim.py` (DB harus hasil `DEV=accounts`).

## 4. Membaca hasil
- `PASS` / `FAIL` per asersi; ringkasan di baris terakhir.
- `!!` di depan baris (run.sh) = error SQL tak terduga, biasanya akibat migrasi atau tes diubah. Periksa pesan di bawahnya.
- Jika `GAGAL > 0`, jalankan ulang dan simpan keluaran: `./tests/run.sh > hasil.txt 2>&1`, lalu cari `FAIL`.

## 5. Menambah tes
- SQL: tambahkan di `tests/test_schema.sql` memakai helper `t.assert(kondisi, 'deskripsi')`, `t.fails('deskripsi', $q$SQL$q$, 'potongan pesan error')`, dan `t.works('deskripsi', $q$SQL$q$)`. Untuk menguji sebagai aplikasi: `SET ROLE complex_app;` lalu `SELECT set_config('app.user_id','<uuid>',false);`, dan `RESET ROLE;` setelahnya.
- Python: tambahkan `check("deskripsi", kondisi)` di `tests/login_sim.py`. Untuk "memajukan waktu" ubah `created_at` **dan** `expires_at` bersama-sama lewat koneksi `owner` (CHECK DB menolak jika hanya salah satu).
- Wajib dijalankan ulang kedua rangkaian setiap kali mengubah file di `db/`.

## 6. Masalah umum
| Gejala | Solusi |
|---|---|
| `MIGRASI GAGAL` | server mati / bukan superuser / versi PostgreSQL < 15; cek `psql -d postgres -c "select version()"` |
| `permission denied to create database` | gunakan superuser (`PGUSER=postgres`) |
| `ModuleNotFoundError: psycopg` atau `argon2` | `pip install -r requirements-dev.txt` (untuk Python milik user yang menjalankan) |
| `connection refused` | server belum hidup: `docker compose up -d` / `brew services start postgresql@16` / `sudo pg_ctlcluster 16 main start` |
| `database "complex_test" is being accessed by other users` | tutup sesi psql/GUI yang membuka DB itu |
| Simulasi gagal di "warga aktif login" | DB tidak segar (sudah pernah dijalankan); gunakan `run_sim.sh`, bukan `login_sim.py` langsung |
