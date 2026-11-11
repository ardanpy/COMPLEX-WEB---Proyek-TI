# COMPLEX — Backend Laravel (overlay)

Folder ini berisi **hanya berkas yang kita tulis**, untuk ditimpakan ke proyek Laravel baru (Laravel 11/12, PHP >= 8.2, ekstensi pgsql, gd, sodium/argon2 bawaan).
Skema database tetap milik `../db/*.sql` — Laravel TIDAK membuat tabel (tanpa migration, tanpa Eloquent untuk tabel inti).

## Pasang
```bash
composer create-project laravel/laravel complex-api && cd complex-api
composer require intervention/image
rm database/migrations/*.php                 # migrasi bawaan (users/cache/jobs) bentrok dengan skema kita
cp -r <repo>/complex_db_DRAFT/laravel/{bootstrap,config,routes,app,tests} .       # timpa
cat <repo>/complex_db_DRAFT/laravel/.env.complex.example >> .env                  # lalu rapikan/ubah duplikat
php artisan key:generate
# php.ini: upload_max_filesize=6M, post_max_size=8M  (default 2M akan menolak foto absen)
php artisan serve
```
Database: `DB=complex DEV=accounts ./scripts/migrate.sh` lalu `ALTER ROLE complex_app WITH LOGIN PASSWORD '...'`.

## Yang sengaja BERBEDA dari Laravel biasa
- Tidak memakai session/Auth/CSRF bawaan Laravel: autentikasi = cookie `sid` opaque (DB hanya menyimpan SHA-256) -> `fn_session_user()`; CSRF = header `X-CSRF-Token` + cek `Origin`.
- Setiap request berakun berjalan di transaksi dengan `app.user_id` (`App\Support\Db::as`) agar RLS PostgreSQL bekerja. Jangan memakai `DB::` di luar pembungkus itu untuk data pengguna.
- Hanya query terparameter (`?`). bytea dikirim sebagai hex + `decode(?, 'hex')`.
- Satpam mengubah status laporan hanya lewat `fn_security_set_report_status`.

## Status
Ditulis tanpa bisa dijalankan (lingkungan penulis tanpa PHP/Composer/PostgreSQL): **belum diuji sama sekali**. Berkas di `tests/Unit` hanya menguji fungsi murni.
Endpoint: `../backend/docs/API.md` (+ `PATCH /security/reports/{id}/status`, `GET /admin/report-log`). Belum ada: modul warga (lapor, kebersihan, fasilitas, iuran), komunitas, pengumuman/acara, notifikasi, SIGAP, foto profil.
