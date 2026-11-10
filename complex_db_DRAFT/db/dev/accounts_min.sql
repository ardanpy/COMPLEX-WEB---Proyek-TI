-- =====================================================================
-- AKUN UJI — HANYA UNTUK DEVELOPMENT (jangan dijalankan di produksi).
-- 1 admin + 2 warga untuk menguji alur login. Semua berpassword:  Complex#Test2026
-- Hash di bawah Argon2id (m=19456, t=2, p=1) = parameter yang sama dengan produksi.
--
--   admin@complex.test  admin   sudah aktif
--   budi@complex.test   warga   Jati 1 / 52   sudah aktif
--   sari@complex.test   warga   Jati 2 / 15   BELUM AKTIF (activated_at NULL) -> uji alur login pertama (OTP email)
-- =====================================================================
INSERT INTO users (id, email, full_name, role, password_hash, activated_at)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@complex.test', 'Pengurus Admin', 'admin',
        '$argon2id$v=19$m=19456,t=2,p=1$b3J+B8yFWAP1hlwY2vLTyg$J2upnmKOyh9N8kr/lgw+UchTKHIj5wT0+9OIZaS4S1E', now());

INSERT INTO units (block_id, house_number)
SELECT b.id, v.h FROM (VALUES ('Jati 1', '52'), ('Jati 2', '15')) v(blk, h) JOIN blocks b ON b.name = v.blk;

INSERT INTO users (id, email, full_name, phone, unit_id, password_hash, activated_at, created_by) VALUES
 ('00000000-0000-0000-0000-0000000000b1', 'budi@complex.test', 'Budi Santoso', '6281200000001',
    (SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id WHERE b.name = 'Jati 1' AND u.house_number = '52'),
    '$argon2id$v=19$m=19456,t=2,p=1$JKiyglca9jj3vKrspTCAUw$+jAjEpk54PB+8gN8b4asvgnH7X7rk/IqBYnMbrDqvak', now(), '00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000000b2', 'sari@complex.test', 'Sari Wulandari', '6281200000002',
    (SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id WHERE b.name = 'Jati 2' AND u.house_number = '15'),
    '$argon2id$v=19$m=19456,t=2,p=1$Zza1w9fEWJjheh9Omm84KA$JcNjRdIBHrdke+eNtW8rPZK5+PCrM5oPTqpozoB7/gY', NULL, '00000000-0000-0000-0000-0000000000a1');

-- satpam@complex.test  security  sudah aktif (password sama) -> uji absen foto & ubah status laporan
INSERT INTO users (id, email, full_name, phone, role, password_hash, activated_at, created_by) VALUES
 ('00000000-0000-0000-0000-0000000000e1', 'satpam@complex.test', 'Satpam Contoh', '6281300000001', 'security',
  '$argon2id$v=19$m=19456,t=2,p=1$b3J+B8yFWAP1hlwY2vLTyg$J2upnmKOyh9N8kr/lgw+UchTKHIj5wT0+9OIZaS4S1E', now(), '00000000-0000-0000-0000-0000000000a1');
