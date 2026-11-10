# Catatan: framework
Tim memutuskan memakai **Laravel**. Folder ini (Node/Fastify) adalah implementasi referensi tahap 1 dan **akan digantikan** oleh proyek Laravel.
Yang tetap berlaku: kontrak endpoint (`docs/API.md`), pola keamanan (cookie opaque + SHA-256 di DB, `app.user_id` per transaksi,
OTP HMAC dengan pepper, Argon2id, pemrosesan foto), dan seluruh SQL di `complex_db_DRAFT/db/`.
Endpoint baru yang belum ada di kode Node: `PATCH /security/reports/{id}/status` (body: status, note) -> `fn_security_set_report_status`.
