-- Membuat akun admin (dijalankan dengan role PEMILIK DB, bukan complex_app).
-- Pemakaian:  psql -d complex -v email=... -v name=... -v hash=... [-v creator=email_admin_lama] -f create_admin.sql
-- Admin pertama: tanpa creator. Admin berikutnya: creator = email admin aktif yang sudah ada.
INSERT INTO users (email, full_name, role, password_hash, must_change_password, created_by)
VALUES (lower(:'email'), :'name', 'admin', :'hash', true,
        (SELECT id FROM users WHERE email = lower(NULLIF(:'creator', '')) AND role = 'admin' AND status = 'aktif'))
RETURNING id, email, role;
