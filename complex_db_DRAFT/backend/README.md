# COMPLEX — Backend API (referensi Node.js/Fastify; akan digantikan Laravel, lihat NOTE_FRAMEWORK.md)

Bagian dari Proyek TI Web CompleX. Berbicara dengan PostgreSQL lewat role `complex_app` (hak akses minimal + RLS), semua query terparameter.

## Jalankan
```bash
DB=complex DEV=accounts ./scripts/migrate.sh        # dari folder complex_db_DRAFT: skema 01-12 + akun uji
psql -d complex -c "ALTER ROLE complex_app WITH LOGIN PASSWORD '<acak>'"
cd backend && cp .env.example .env     # isi DATABASE_URL, OTP_PEPPER (>=32 byte), ALLOWED_ORIGIN
npm install && set -a && . ./.env && set +a && npm start
npm test                                  # tes unit (foto, password, OTP); tes integrasi API belum ada
```
Tanpa SMTP, kode OTP dicetak di log server (hanya non-production).

## Endpoint
Ringkasan lengkap: `docs/API.md`.

## Keamanan yang diterapkan di API
Cookie sesi opaque `HttpOnly; SameSite=Strict` (+`Secure` di produksi), DB hanya menyimpan SHA-256; role selalu dari DB;
CSRF token (header `x-csrf-token`) + pemeriksaan `Origin`; rate limit global dan per endpoint sensitif; Argon2id; respons login/OTP generik;
waktu respons disamakan untuk email tak dikenal; unggah foto dicek isi sebenarnya, di-encode ulang (EXIF/GPS dibuang), nama acak;
galat 500 tidak membocorkan detail SQL.
