-- =====================================================================
-- DATA DEMO — HANYA UNTUK DEVELOPMENT. Memetakan data contoh di frontend.
-- Semua akun demo berpassword:  Demo#Password1   (bcrypt cost 4, bukan untuk produksi)
-- =====================================================================
INSERT INTO users (id, email, full_name, role, password_hash, must_change_password)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@complex.test', 'Pengurus Admin', 'admin',
        crypt('Demo#Password1', gen_salt('bf', 4)), false);

INSERT INTO units (block_id, house_number)
SELECT b.id, h FROM blocks b, (VALUES ('52'), ('15'), ('7')) v(h) WHERE b.name IN ('Jati 1', 'Jati 2', 'Jati 3');

INSERT INTO users (id, email, full_name, phone, unit_id, password_hash, must_change_password, created_by) VALUES
 ('00000000-0000-0000-0000-0000000000b1', 'budi@complex.test',  'Budi Santoso',  '6281200000001',
    (SELECT u.id FROM units u JOIN blocks b ON b.id=u.block_id WHERE b.name='Jati 1' AND u.house_number='52'), crypt('Demo#Password1', gen_salt('bf', 4)), false, '00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000000b2', 'sari@complex.test',  'Sari Wulandari','6281200000002',
    (SELECT u.id FROM units u JOIN blocks b ON b.id=u.block_id WHERE b.name='Jati 2' AND u.house_number='15'), crypt('Demo#Password1', gen_salt('bf', 4)), false, '00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000000b3', 'andre@complex.test', 'Andre Pratama', '6281200000003',
    (SELECT u.id FROM units u JOIN blocks b ON b.id=u.block_id WHERE b.name='Jati 3' AND u.house_number='7'),  crypt('Demo#Password1', gen_salt('bf', 4)), false, '00000000-0000-0000-0000-0000000000a1');

UPDATE security_guards SET name = 'Pak Hendra', phone = '6281300000001' WHERE slot = 1;
UPDATE security_guards SET name = 'Pak Joko',   phone = '6281300000002' WHERE slot = 2;
UPDATE security_shift_config SET configured = true;

-- laporan (pemetaan status frontend: Baru->dikirim, Ditangani->diproses)
INSERT INTO reports (reporter_id, category, title, description, location_text, incident_date, status, recipient) VALUES
 ('00000000-0000-0000-0000-0000000000b1','kebersihan','Sampah menumpuk Jati 1','Sampah menumpuk di area Jati 1 dan menunggu penanganan petugas.','Jati 1','2026-10-14','diproses','penanggung_jawab_kebersihan'),
 ('00000000-0000-0000-0000-0000000000b2','kebersihan','Selokan tersumbat Jati 3','Saluran air di Jati 3 tersumbat oleh sampah.','Jati 3','2026-10-14','dikirim','pengurus_rt'),
 ('00000000-0000-0000-0000-0000000000b3','fasilitas','Lampu jalan mati','Lampu penerangan jalan tidak menyala pada malam hari.','Jalan utama Jati 2','2026-10-12','dikirim',NULL),
 ('00000000-0000-0000-0000-0000000000b1','keamanan','Orang tidak dikenal','Orang tidak dikenal terlihat berulang kali di sekitar gerbang utama.','Dekat gerbang utama','2026-10-08','selesai',NULL);

INSERT INTO events (title, description, location, starts_at, created_by) VALUES
 ('Gotong Royong Mingguan', 'Kerja bakti warga.', 'Area Taman Jati 1-4', '2026-11-07 07:00+07', '00000000-0000-0000-0000-0000000000a1'),
 ('Pengajian Masjid Al-Husna', 'Pengajian bulanan.', 'Masjid Al-Husna', '2026-11-12 19:30+07', '00000000-0000-0000-0000-0000000000a1');

INSERT INTO announcements (category, title, body, created_by) VALUES
 ('komplek', 'Kerja bakti warga hari Sabtu', 'Kerja bakti warga hari Sabtu pukul 06.30. Mohon membawa peralatan kebersihan masing-masing.', '00000000-0000-0000-0000-0000000000a1');

INSERT INTO dues_bills (unit_id, period, amount_idr, due_date)
SELECT id, date_trunc('month', CURRENT_DATE)::date, 150000, (date_trunc('month', CURRENT_DATE) + interval '9 days')::date FROM units;

WITH p AS (INSERT INTO posts (author_id, body) VALUES
  ('00000000-0000-0000-0000-0000000000b2', 'Ada yang kehilangan kucing oranye di sekitar Jati 2?') RETURNING id)
INSERT INTO post_comments (post_id, author_id, body)
SELECT id, '00000000-0000-0000-0000-0000000000b1', 'Kemarin sempat lihat di dekat taman.' FROM p;
INSERT INTO post_likes (post_id, user_id) SELECT id, '00000000-0000-0000-0000-0000000000b1' FROM posts;
