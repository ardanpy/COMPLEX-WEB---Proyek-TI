-- Membuat akun admin (dijalankan dengan role PEMILIK DB, bukan complex_app).
-- Pemakaian:  psql -d complex -v email=... -v name=... -v hash=... -v creator=... -v activated=0|1 -f create_admin.sql
-- Admin pertama: creator kosong. Admin berikutnya: creator = email admin aktif yang sudah ada.
-- activated=0 (bawaan): admin harus login pertama via OTP email lalu set password sendiri.
-- activated=1 : langsung aktif (HANYA untuk bootstrap darurat/dev saat email belum tersedia).
INSERT INTO users (email, full_name, role, password_hash, activated_at, created_by)
VALUES (lower(:'email'), :'name', 'admin', :'hash',
        CASE WHEN :'activated' = '1' THEN now() END,
        (SELECT id FROM users WHERE email = lower(NULLIF(:'creator', '')) AND role = 'admin' AND status = 'aktif'))
RETURNING id, email, role, activated_at IS NOT NULL AS activated;
