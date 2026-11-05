-- Uji otomatis skema COMPLEX. Dijalankan oleh tests/run.sh pada DB yang sudah di-migrate + demo seed.
\set VERBOSITY terse
CREATE SCHEMA t;
CREATE FUNCTION t.assert(cond boolean, name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS TRUE THEN RAISE NOTICE 'PASS  %', name; ELSE RAISE NOTICE 'FAIL  %', name; END IF; END $$;
CREATE FUNCTION t.fails(name text, stmt text, frag text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
DECLARE ok boolean := false; msg text;
BEGIN
  BEGIN EXECUTE stmt; ok := true;
  EXCEPTION WHEN others THEN msg := SQLERRM; END;
  IF ok THEN RAISE NOTICE 'FAIL  % (seharusnya ditolak, tetapi berhasil)', name;
  ELSIF frag = '' OR position(lower(frag) in lower(msg)) > 0 THEN RAISE NOTICE 'PASS  %', name;
  ELSE RAISE NOTICE 'FAIL  % (error berbeda: %)', name, msg; END IF;
END $$;
CREATE FUNCTION t.works(name text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE stmt; RAISE NOTICE 'PASS  %', name;
EXCEPTION WHEN others THEN RAISE NOTICE 'FAIL  % (error: %)', name, SQLERRM; END $$;
GRANT USAGE ON SCHEMA t TO complex_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO complex_app;

-- id tetap dari demo seed: admin=a1, budi=b1 (Jati 1/52), sari=b2 (Jati 2/15), andre=b3 (Jati 3/7)

\echo '=== A. Constraint & guard (sebagai pemilik DB) ==='
SELECT t.fails('warga tanpa rumah ditolak',
  $q$INSERT INTO users(email,full_name,password_hash,created_by) VALUES('x1@t.id','Xx','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','00000000-0000-0000-0000-0000000000a1')$q$, 'warga_wajib_punya_rumah');
SELECT t.fails('warga tanpa pendaftar (admin) ditolak',
  $q$INSERT INTO users(email,full_name,password_hash,unit_id) VALUES('x2@t.id','Xx','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',(SELECT min(id) FROM units))$q$, 'warga_wajib_didaftarkan_admin');
SELECT t.fails('password plaintext ditolak',
  $q$INSERT INTO users(email,full_name,password_hash,unit_id,created_by) VALUES('x3@t.id','Xx','passwordku123',(SELECT min(id) FROM units),'00000000-0000-0000-0000-0000000000a1')$q$, 'password_hash');
SELECT t.fails('email huruf besar ditolak (wajib lowercase)',
  $q$INSERT INTO users(email,full_name,password_hash,unit_id,created_by) VALUES('X4@T.id','Xx','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',(SELECT min(id) FROM units),'00000000-0000-0000-0000-0000000000a1')$q$, 'users_email_check');
SELECT t.fails('email duplikat ditolak',
  $q$INSERT INTO users(email,full_name,password_hash,unit_id,created_by) VALUES('budi@complex.test','Dup','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',(SELECT min(id) FROM units),'00000000-0000-0000-0000-0000000000a1')$q$, 'users_email_uq');
SELECT t.fails('created_by harus admin (warga tidak bisa mendaftarkan warga)',
  $q$INSERT INTO users(email,full_name,password_hash,unit_id,created_by) VALUES('x5@t.id','Xx','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',(SELECT min(id) FROM units),'00000000-0000-0000-0000-0000000000b1')$q$, 'created_by harus merujuk admin');
SELECT t.fails('admin kedua tanpa created_by ditolak',
  $q$INSERT INTO users(email,full_name,role,password_hash) VALUES('adm2@t.id','Adm Dua','admin','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')$q$, 'created_by');
SELECT t.fails('admin aktif terakhir tidak bisa dinonaktifkan',
  $q$UPDATE users SET status='nonaktif' WHERE id='00000000-0000-0000-0000-0000000000a1'$q$, 'admin aktif terakhir');
SELECT t.fails('notifikasi dengan link javascript: ditolak',
  $q$INSERT INTO notifications(category,title,link) VALUES('sistem','x','javascript:alert(1)')$q$, 'notifications_link_check');
SELECT t.fails('notifikasi dengan link eksternal ditolak',
  $q$INSERT INTO notifications(category,title,link) VALUES('sistem','x','https://evil.example/phish.html')$q$, 'notifications_link_check');
SELECT t.fails('storage_key path traversal ditolak',
  $q$INSERT INTO post_media(post_id,position,kind,mime_type,storage_key,size_bytes) VALUES((SELECT id FROM posts LIMIT 1),1,'image','image/png','../../etc/passwd',100)$q$, 'storage_key');
SELECT t.fails('mime berbahaya (text/html) ditolak',
  $q$INSERT INTO post_media(post_id,position,kind,mime_type,storage_key,size_bytes) VALUES((SELECT id FROM posts LIMIT 1),1,'image','text/html','11111111-1111-1111-1111-111111111111.png',100)$q$, 'check constraint');
SELECT t.fails('media posisi ke-5 ditolak (maks 4 file)',
  $q$INSERT INTO post_media(post_id,position,kind,mime_type,storage_key,size_bytes) VALUES((SELECT id FROM posts LIMIT 1),5,'image','image/png','22222222-2222-2222-2222-222222222222.png',100)$q$, 'position');

\echo '=== B. Fasilitas: validasi & anti-bentrok jadwal ==='
SELECT t.fails('ambulans tidak boleh punya jam selesai',
  $q$INSERT INTO facility_requests(facility,requester_id,applicant_name,applicant_phone,address_text,use_date,start_time,end_time,purpose,pickup_location,destination,patient_count)
     VALUES('ambulans','00000000-0000-0000-0000-0000000000b1','Budi','6281200000001','Jati 1 No. 52','2030-01-01','08:00','09:00','Antar pasien','Rumah','RS',1)$q$, 'ambulans_rules');
SELECT t.fails('lapangan wajib jam selesai > jam mulai',
  $q$INSERT INTO facility_requests(facility,requester_id,applicant_name,applicant_phone,address_text,use_date,start_time,end_time,purpose,participant_count)
     VALUES('lapangan','00000000-0000-0000-0000-0000000000b1','Budi','6281200000001','Jati 1 No. 52','2030-01-01','10:00','09:00','Olahraga warga',10)$q$, 'venue_rules');
INSERT INTO facility_requests(facility,requester_id,applicant_name,applicant_phone,address_text,use_date,start_time,end_time,purpose,participant_count) VALUES
 ('lapangan','00000000-0000-0000-0000-0000000000b1','Budi','6281200000001','Jati 1 No. 52','2030-01-01','08:00','10:00','Olahraga warga',20),
 ('lapangan','00000000-0000-0000-0000-0000000000b2','Sari','6281200000002','Jati 2 No. 15','2030-01-01','09:00','11:00','Latihan rutin',15),
 ('lapangan','00000000-0000-0000-0000-0000000000b3','Andre','6281200000003','Jati 3 No. 7','2030-01-01','10:00','12:00','Acara warga',30);
SELECT t.assert((SELECT count(*) FROM facility_requests WHERE use_date='2030-01-01')=3, 'pengajuan yang beririsan boleh ANTRI (menunggu)');
UPDATE facility_requests SET status='disetujui' WHERE use_date='2030-01-01' AND applicant_name='Budi';
SELECT t.fails('menyetujui jadwal yang bentrok ditolak (exclusion constraint)',
  $q$UPDATE facility_requests SET status='disetujui' WHERE use_date='2030-01-01' AND applicant_name='Sari'$q$, 'no_double_booking');
SELECT t.works('jadwal bersebelahan (10:00 tepat) boleh disetujui',
  $q$UPDATE facility_requests SET status='disetujui' WHERE use_date='2030-01-01' AND applicant_name='Andre'$q$);
SELECT t.assert((SELECT decided_at IS NOT NULL FROM facility_requests WHERE applicant_name='Budi' AND use_date='2030-01-01'), 'decided_at terisi otomatis saat keputusan');

\echo '=== C. Laporan, notifikasi, SIGAP, login ==='
UPDATE reports SET status='selesai' WHERE title='Selokan tersumbat Jati 3';
SELECT t.assert((SELECT count(*) FROM report_status_history h JOIN reports r ON r.id=h.report_id WHERE r.title='Selokan tersumbat Jati 3')=2, 'riwayat status laporan tercatat (dikirim -> selesai)');
SELECT t.assert((SELECT resolved_at IS NOT NULL FROM reports WHERE title='Selokan tersumbat Jati 3'), 'resolved_at terisi saat selesai');
SELECT t.assert(EXISTS(SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id
   WHERE nr.user_id='00000000-0000-0000-0000-0000000000b2' AND n.title='Status laporan diperbarui'), 'pelapor menerima notifikasi perubahan status');
SELECT t.assert((SELECT count(*) FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.announcement_id IS NOT NULL)
  = (SELECT count(*) FROM users WHERE status='aktif' AND role IN ('admin','warga')), 'pengumuman di-fanout ke seluruh pengguna aktif (admin & warga)');
SELECT t.fails('report_recipient hanya untuk kategori kebersihan',
  $q$INSERT INTO reports(reporter_id,category,title,description,location_text,recipient) VALUES('00000000-0000-0000-0000-0000000000b1','keamanan','abc','x','y','pengurus_rt')$q$, 'reports_check');
INSERT INTO sigap_alerts(user_id) VALUES ('00000000-0000-0000-0000-0000000000b1');
SELECT t.fails('1 pengguna tidak bisa punya 2 alarm SIGAP aktif (anti-spam)',
  $q$INSERT INTO sigap_alerts(user_id) VALUES ('00000000-0000-0000-0000-0000000000b1')$q$, 'sigap_one_active_per_user');
UPDATE sigap_alerts SET status='menuju_lokasi' WHERE user_id='00000000-0000-0000-0000-0000000000b1';
SELECT t.assert((SELECT dispatched_at IS NOT NULL FROM sigap_alerts WHERE user_id='00000000-0000-0000-0000-0000000000b1'), 'SIGAP: dispatched_at terisi otomatis');
SELECT t.assert(EXISTS(SELECT 1 FROM notifications WHERE title='SIGAP: peringatan darurat'), 'SIGAP: admin mendapat notifikasi');

SELECT fn_login_failed('00000000-0000-0000-0000-0000000000b3','andre@complex.test','10.0.0.9') FROM generate_series(1,4);
SELECT t.assert((SELECT locked_until IS NULL FROM users WHERE id='00000000-0000-0000-0000-0000000000b3'), 'akun belum terkunci setelah 4 gagal');
SELECT fn_login_failed('00000000-0000-0000-0000-0000000000b3','andre@complex.test','10.0.0.9');
SELECT t.assert((SELECT locked_until > now() AND failed_login_count=5 FROM users WHERE id='00000000-0000-0000-0000-0000000000b3'), 'akun terkunci 15 menit setelah 5 gagal');
SELECT t.assert(EXISTS(SELECT 1 FROM audit_logs WHERE action='ACCOUNT_LOCKED'), 'penguncian akun tercatat di audit');
SELECT fn_login_succeeded('00000000-0000-0000-0000-0000000000b3','andre@complex.test','10.0.0.9');
SELECT t.assert((SELECT locked_until IS NULL AND failed_login_count=0 AND last_login_at IS NOT NULL FROM users WHERE id='00000000-0000-0000-0000-0000000000b3'), 'login sukses mereset penghitung & kunci');

\echo '=== D. Audit append-only & tidak membocorkan hash ==='
SELECT t.fails('UPDATE audit_logs ditolak (bahkan untuk pemilik)', $q$UPDATE audit_logs SET action='x'$q$, 'append-only');
SELECT t.fails('DELETE audit_logs ditolak', $q$DELETE FROM audit_logs$q$, 'append-only');
SELECT t.fails('TRUNCATE audit_logs ditolak', $q$TRUNCATE audit_logs$q$, 'append-only');
SELECT t.assert(NOT EXISTS(SELECT 1 FROM audit_logs WHERE details::text ~ '\$2a\$|argon2'), 'audit tidak menyimpan hash password');
SELECT t.assert(EXISTS(SELECT 1 FROM audit_logs WHERE entity='users' AND details ? 'new'), 'audit mencatat pembuatan akun');

\echo '=== E. Parameterized query vs payload SQL injection ==='
CREATE FUNCTION t.login_lookup(p_email text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT count(*) FROM users WHERE email = p_email $$;
SELECT t.assert(t.login_lookup($$' OR '1'='1$$)=0, 'payload  '' OR ''1''=''1  sebagai parameter = data biasa (0 baris)');
SELECT t.assert(t.login_lookup($$x'; DROP TABLE users;--$$)=0 AND to_regclass('users') IS NOT NULL, 'payload stacked DROP TABLE tidak dieksekusi');

\echo '=== F. Role aplikasi (complex_app): hak akses minimal ==='
SET ROLE complex_app;
SELECT t.fails('tanpa sesi, app tidak bisa membuat akun apa pun (tidak ada pendaftaran mandiri)',
  $q$INSERT INTO users(email,full_name,password_hash,unit_id,created_by) VALUES('mandiri@t.id','Mandiri','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',(SELECT min(id) FROM units),'00000000-0000-0000-0000-0000000000a1')$q$, 'Hanya admin');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.fails('bahkan sesi admin lewat app tidak bisa membuat akun ADMIN',
  $q$INSERT INTO users(email,full_name,role,password_hash,created_by) VALUES('hack@t.id','Hack','admin','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','00000000-0000-0000-0000-0000000000a1')$q$, 'admin hanya dapat dibuat');
RESET app.user_id;
SELECT t.fails('app tidak bisa mengubah kolom role (privilege-escalation)',
  $q$UPDATE users SET role='admin' WHERE id='00000000-0000-0000-0000-0000000000b1'$q$, 'permission denied');
SELECT t.fails('app tidak bisa DELETE users', $q$DELETE FROM users$q$, 'permission denied');
SELECT t.fails('app tidak bisa UPDATE audit_logs', $q$UPDATE audit_logs SET action='x'$q$, 'permission denied');
SELECT t.fails('app tidak bisa DELETE audit_logs', $q$DELETE FROM audit_logs$q$, 'permission denied');
SELECT t.fails('app tidak bisa DDL (CREATE TABLE)', $q$CREATE TABLE pwn(x int)$q$, 'permission denied');
SELECT t.fails('app tidak bisa DROP TABLE', $q$DROP TABLE users$q$, 'must be owner');
SELECT t.fails('app tidak bisa menulis notifikasi langsung', $q$INSERT INTO notifications(category,title) VALUES('sistem','spoof')$q$, 'permission denied');
SELECT t.fails('app tidak bisa mengubah created_by', $q$UPDATE users SET created_by=NULL$q$, 'permission denied');
SELECT t.assert(EXISTS(SELECT 1 FROM pg_roles WHERE rolname='complex_app' AND rolconfig::text LIKE '%statement_timeout%'), 'statement_timeout terpasang pada role app');
SELECT t.assert(NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='v_community_members' AND column_name IN ('email','phone','password_hash')), 'view anggota komunitas tanpa email/telepon/hash');
RESET ROLE;

\echo '=== G. RLS: isolasi data antar pengguna ==='
SET ROLE complex_app;
RESET app.user_id;
SELECT t.assert((SELECT count(*) FROM reports)=0 AND (SELECT count(*) FROM facility_requests)=0 AND (SELECT count(*) FROM notification_recipients)=0, 'tanpa sesi (user_id kosong): tidak ada data bisnis terbaca');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert((SELECT count(*) FROM facility_requests)=1, 'budi hanya melihat pengajuan fasilitas miliknya (1 dari 3)');
SELECT t.assert((SELECT count(*) FROM notification_recipients WHERE user_id<>'00000000-0000-0000-0000-0000000000b1')=0, 'budi tidak melihat notifikasi orang lain');
SELECT t.fails('budi tidak bisa membuat pengajuan atas nama sari',
  $q$INSERT INTO facility_requests(facility,requester_id,applicant_name,applicant_phone,address_text,use_date,start_time,end_time,purpose,participant_count)
     VALUES('mushola','00000000-0000-0000-0000-0000000000b2','Sari','6281200000002','x','2030-02-01','08:00','09:00','Kajian / pengajian',10)$q$, 'row-level security');
SELECT t.works('budi bisa membuat pengajuan atas nama sendiri',
  $q$INSERT INTO facility_requests(facility,requester_id,applicant_name,applicant_phone,address_text,use_date,start_time,end_time,purpose,participant_count)
     VALUES('mushola','00000000-0000-0000-0000-0000000000b1','Budi','6281200000001','Jati 1 No. 52','2030-02-01','08:00','09:00','Kajian / pengajian',10)$q$);
SELECT t.fails('budi tidak bisa langsung menyetujui pengajuannya sendiri',
  $q$INSERT INTO facility_requests(facility,requester_id,applicant_name,applicant_phone,address_text,use_date,start_time,end_time,purpose,participant_count,status)
     VALUES('mushola','00000000-0000-0000-0000-0000000000b1','Budi','6281200000001','x','2030-02-02','08:00','09:00','Kajian / pengajian',10,'disetujui')$q$, 'row-level security');
WITH u AS (UPDATE reports SET status='selesai' RETURNING 1) SELECT t.assert((SELECT count(*) FROM u)=0, 'warga tidak bisa mengubah status laporan (0 baris terubah)');
SELECT t.fails('warga tidak bisa menyetujui pengajuan sendiri via UPDATE', $q$UPDATE facility_requests SET status='disetujui' WHERE applicant_name='Budi'$q$, 'row-level security');
WITH u AS (UPDATE facility_requests SET status='dibatalkan' WHERE use_date='2030-02-01' RETURNING 1) SELECT t.assert((SELECT count(*) FROM u)=1, 'warga bisa membatalkan pengajuan yang masih menunggu');
WITH u AS (UPDATE facility_requests SET status='dibatalkan' WHERE use_date='2030-01-01' AND applicant_name='Budi' RETURNING 1) SELECT t.assert((SELECT count(*) FROM u)=0, 'warga tidak bisa membatalkan yang sudah disetujui');
WITH u AS (UPDATE posts SET body='diretas' RETURNING 1) SELECT t.assert((SELECT count(*) FROM u)=0, 'budi tidak bisa mengedit postingan sari');
SELECT t.works('warga bisa memposting', $q$INSERT INTO posts(author_id,body) VALUES('00000000-0000-0000-0000-0000000000b1','Halo tetangga')$q$);
SELECT t.fails('warga tidak bisa memposting atas nama orang lain', $q$INSERT INTO posts(author_id,body) VALUES('00000000-0000-0000-0000-0000000000b2','palsu')$q$, 'row-level security');
SELECT t.works('warga bisa menandai notifikasi sendiri dibaca', $q$UPDATE notification_recipients SET read_at=now() WHERE read_at IS NULL$q$);
SELECT t.assert((SELECT count(*) FROM sigap_alerts)=1, 'budi hanya melihat alarm SIGAP miliknya');
SELECT t.assert((SELECT count(*) FROM audit_logs)=0, 'warga tidak bisa membaca audit log');

SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b2',false);
SELECT t.assert((SELECT count(*) FROM facility_requests)=1 AND (SELECT count(*) FROM facility_requests WHERE applicant_name='Sari')=1, 'sari hanya melihat pengajuannya sendiri');
SELECT t.assert((SELECT count(*) FROM sigap_alerts)=0, 'sari tidak melihat SIGAP milik budi');
SELECT t.fails('warga tidak bisa mengubah blok/nomor rumahnya sendiri',
  $q$UPDATE users SET unit_id=(SELECT id FROM units ORDER BY id DESC LIMIT 1) WHERE id='00000000-0000-0000-0000-0000000000b2'$q$, 'hanya dapat diubah admin');
SELECT t.fails('warga tidak bisa mengubah status akunnya sendiri',
  $q$UPDATE users SET status='ditangguhkan' WHERE id='00000000-0000-0000-0000-0000000000b2'$q$, 'hanya dapat diubah admin');
SELECT t.fails('warga tidak bisa mengubah profil warga lain (IDOR)',
  $q$UPDATE users SET full_name='Diretas' WHERE id='00000000-0000-0000-0000-0000000000b1'$q$, 'akunnya sendiri');
SELECT t.works('warga bisa mengubah nama/telepon akunnya sendiri',
  $q$UPDATE users SET phone='6281211112222' WHERE id='00000000-0000-0000-0000-0000000000b2'$q$);
SELECT t.works('warga bisa mengisi kunci foto profil (nama dibuat server)',
  $q$UPDATE users SET photo_storage_key='3f2b8c1e-5a7d-4e9f-8b21-0c4d6e7f8a90.webp' WHERE id='00000000-0000-0000-0000-0000000000b2'$q$);
SELECT t.fails('kunci foto path traversal ditolak',
  $q$UPDATE users SET photo_storage_key='../../etc/passwd' WHERE id='00000000-0000-0000-0000-0000000000b2'$q$, 'photo_storage_key');
SELECT t.fails('kunci foto dengan ekstensi berbahaya (.php) ditolak',
  $q$UPDATE users SET photo_storage_key='3f2b8c1e-5a7d-4e9f-8b21-0c4d6e7f8a90.php' WHERE id='00000000-0000-0000-0000-0000000000b2'$q$, 'photo_storage_key');
SELECT t.fails('warga tidak bisa mengganti foto warga lain',
  $q$UPDATE users SET photo_storage_key='3f2b8c1e-5a7d-4e9f-8b21-0c4d6e7f8a91.png' WHERE id='00000000-0000-0000-0000-0000000000b1'$q$, 'akunnya sendiri');
SELECT t.assert((SELECT count(*) FROM dues_bills)=1 AND (SELECT unit_id FROM dues_bills)=(SELECT unit_id FROM users WHERE id='00000000-0000-0000-0000-0000000000b2'), 'sari hanya melihat tagihan iuran rumahnya');

SELECT set_config('app.user_id',gen_random_uuid()::text,false);
SELECT t.assert(NOT app_is_admin(), 'user_id palsu/tak dikenal tidak dianggap admin');
SELECT set_config('app.user_role','admin',false);
SELECT t.assert(NOT app_is_admin(), 'memalsukan app.user_role=admin tidak memberi hak admin');
SELECT t.assert((SELECT count(*) FROM facility_requests)=0, 'pemalsuan app.user_role tidak membuka data fasilitas');

SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.assert(app_is_admin(), 'admin terverifikasi dari tabel users');
SELECT t.assert((SELECT count(*) FROM facility_requests)=4, 'admin melihat seluruh pengajuan fasilitas (4)');
WITH u AS (UPDATE reports SET status='diproses' WHERE title='Lampu jalan mati' RETURNING 1) SELECT t.assert((SELECT count(*) FROM u)=1, 'admin bisa mengubah status laporan');
SELECT t.assert((SELECT changed_by FROM report_status_history h JOIN reports r ON r.id=h.report_id WHERE r.title='Lampu jalan mati' AND h.to_status='diproses')='00000000-0000-0000-0000-0000000000a1', 'riwayat status mencatat admin pelaku');
SELECT t.assert((SELECT count(*) FROM audit_logs)>0, 'admin dapat membaca audit log');
SELECT t.works('admin (via app) mendaftarkan warga baru',
  $q$INSERT INTO users(email,full_name,phone,unit_id,password_hash,created_by) VALUES('baru@complex.test','Warga Baru','6281200000009',(SELECT id FROM units LIMIT 1),'$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','00000000-0000-0000-0000-0000000000a1')$q$);
SELECT t.assert((SELECT actor_id FROM audit_logs WHERE entity='users' AND details->'new'->>'email'='baru@complex.test')='00000000-0000-0000-0000-0000000000a1', 'audit mencatat admin yang mendaftarkan warga');
SELECT t.works('admin (via app) memindahkan rumah warga',
  $q$UPDATE users SET unit_id=(SELECT id FROM units ORDER BY id DESC LIMIT 1) WHERE id='00000000-0000-0000-0000-0000000000b3'$q$);
SELECT t.works('admin mengubah data petugas keamanan', $q$UPDATE security_guards SET name='Pak Baru' WHERE slot=1$q$);
RESET ROLE;

\echo '=== H. Login pra-autentikasi sebagai app (tanpa user_id) ==='
SET ROLE complex_app;
RESET app.user_id; RESET app.user_role;
SELECT t.assert((SELECT count(*) FROM users WHERE email='budi@complex.test')=1, 'app bisa mencari user berdasarkan email utk login');
SELECT t.works('app bisa mencatat login gagal tanpa sesi', $q$SELECT fn_login_failed(NULL,'tak-ada@x.id','10.1.1.1')$q$);
SELECT t.assert(EXISTS(SELECT 1 FROM login_attempts WHERE email='tak-ada@x.id' AND success=false), 'percobaan login email tak dikenal tercatat');
SELECT t.works('app bisa membuat sesi',
  $q$INSERT INTO sessions(user_id,token_hash,expires_at) VALUES('00000000-0000-0000-0000-0000000000b1', sha256('rahasia'::bytea), now()+interval '8 hours')$q$);
SELECT t.fails('hash sesi bukan 32 byte ditolak (cegah token mentah tersimpan)',
  $q$INSERT INTO sessions(user_id,token_hash,expires_at) VALUES('00000000-0000-0000-0000-0000000000b1','\x0102','2099-01-01')$q$, 'token_hash');
RESET ROLE;


\echo '=== J. OTP: login pertama, lupa password, serangan ==='
CREATE FUNCTION t.h(text) RETURNS bytea LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to($1, 'UTF8')) $$;
GRANT EXECUTE ON FUNCTION t.h(text) TO complex_app;
INSERT INTO users(id,email,full_name,password_hash,unit_id,created_by) VALUES
 ('00000000-0000-0000-0000-0000000000c1','pending@complex.test','Warga Pending','$argon2id$v=19$m=19456,t=2,p=1$aaaa$bbbb',(SELECT min(id) FROM units),'00000000-0000-0000-0000-0000000000a1');
SELECT t.assert((SELECT activated_at IS NULL FROM users WHERE id='00000000-0000-0000-0000-0000000000c1'), 'akun baru dari admin belum aktif (activated_at NULL)');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000b1','activation',t.h('x'))='ineligible', 'OTP aktivasi untuk akun yang sudah aktif ditolak (ineligible)');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000c1','password_reset',t.h('x'))='ineligible', 'OTP lupa-password untuk akun belum aktif ditolak');
SELECT t.assert(fn_otp_issue(gen_random_uuid(),'password_reset',t.h('x'))='ineligible', 'OTP untuk user tak dikenal = ineligible (backend membalas generik)');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000c1','activation',t.h('123456'))='ok', 'OTP aktivasi diterbitkan untuk akun belum aktif');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000c1','activation',t.h('999999'))='cooldown', 'permintaan ulang <60 dtk ditolak (cooldown)');
SELECT t.assert(NOT EXISTS(SELECT 1 FROM otp_challenges WHERE row_to_json(otp_challenges)::text LIKE '%123456%'), 'kode OTP tidak tersimpan sebagai plaintext');
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000c1','activation',t.h('000000'),t.h('T0'))='invalid', 'kode salah -> invalid');
SELECT t.assert((SELECT attempts FROM otp_challenges WHERE user_id='00000000-0000-0000-0000-0000000000c1' AND consumed_at IS NULL AND invalidated_at IS NULL)=1, 'percobaan salah dihitung (1)');
SELECT fn_otp_verify('00000000-0000-0000-0000-0000000000c1','activation',t.h('000001'),t.h('T0')) FROM generate_series(1,3);
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000c1','activation',t.h('000002'),t.h('T0'))='locked', 'kesalahan ke-5 mengunci kode');
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000c1','activation',t.h('123456'),t.h('T1'))='invalid', 'setelah terkunci, kode BENAR pun ditolak (anti brute force)');
SELECT t.assert(NOT EXISTS(SELECT 1 FROM auth_tokens WHERE user_id='00000000-0000-0000-0000-0000000000c1'), 'tidak ada tiket terbit dari kode terkunci');
UPDATE otp_challenges SET created_at = created_at - interval '5 minutes', expires_at = expires_at - interval '5 minutes' WHERE user_id='00000000-0000-0000-0000-0000000000c1';
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000c1','activation',t.h('654321'))='ok', 'setelah cooldown, kode baru dapat diminta');
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000c1','activation',t.h('654321'),t.h('TICKET-C1'))='ok', 'kode benar -> ok');
SELECT t.assert(EXISTS(SELECT 1 FROM auth_tokens WHERE user_id='00000000-0000-0000-0000-0000000000c1' AND purpose='activation' AND used_at IS NULL), 'tiket set-password terbit');
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000c1','activation',t.h('654321'),t.h('TICKET-C2'))='invalid', 'kode yang sama tidak bisa dipakai dua kali');
SELECT t.assert(fn_set_password(t.h('TIKET-SALAH'),'$argon2id$v=19$m=19456,t=2,p=1$new$new') IS NULL, 'tiket palsu ditolak');
SELECT t.fails('hash password baru berbentuk plaintext ditolak oleh DB',
  $q$SELECT fn_set_password(sha256(convert_to('TICKET-C1','UTF8')),'passwordbaru123')$q$, 'password_hash');
SELECT t.assert(fn_set_password(t.h('TICKET-C1'),'$argon2id$v=19$m=19456,t=2,p=1$new$new')='00000000-0000-0000-0000-0000000000c1', 'set password dengan tiket valid -> user id');
SELECT t.assert((SELECT activated_at IS NOT NULL AND password_changed_at IS NOT NULL FROM users WHERE id='00000000-0000-0000-0000-0000000000c1'), 'akun menjadi AKTIF setelah set password');
SELECT t.assert(fn_set_password(t.h('TICKET-C1'),'$argon2id$v=19$m=19456,t=2,p=1$x$x') IS NULL, 'tiket tidak bisa dipakai ulang (replay)');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000c1','activation',t.h('x'))='ineligible', 'akun yang sudah aktif tidak bisa minta OTP aktivasi lagi');

-- lupa password (budi) : kedaluwarsa, pencabutan sesi, batas jam
INSERT INTO sessions(user_id,token_hash,expires_at) VALUES ('00000000-0000-0000-0000-0000000000b1', t.h('sesi-lama'), now()+interval '8 hours');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000b1','password_reset',t.h('111111'))='ok', 'OTP lupa-password diterbitkan untuk akun aktif');
UPDATE otp_challenges SET created_at = now() - interval '20 minutes', expires_at = now() - interval '10 minutes' WHERE user_id='00000000-0000-0000-0000-0000000000b1';
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000b1','password_reset',t.h('111111'),t.h('TB0'))='expired', 'kode kedaluwarsa (10 menit) ditolak walau benar');
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000b1','password_reset',t.h('222222'))='ok', 'kode baru setelah kedaluwarsa');
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000b1','password_reset',t.h('222222'),t.h('TB1'))='ok', 'verifikasi lupa-password ok');
SELECT t.assert(fn_otp_verify('00000000-0000-0000-0000-0000000000b1','activation',t.h('222222'),t.h('TB9'))='invalid', 'kode untuk tujuan lain tidak berlaku silang');
SELECT fn_set_password(t.h('TB1'),'$argon2id$v=19$m=19456,t=2,p=1$b$b');
SELECT t.assert((SELECT revoked_at IS NOT NULL AND revoked_reason='password_changed' FROM sessions WHERE token_hash=t.h('sesi-lama')), 'ganti password mencabut SEMUA sesi lama');
-- batas per jam
DELETE FROM otp_challenges WHERE user_id='00000000-0000-0000-0000-0000000000b3';
DO $$ BEGIN FOR i IN 1..5 LOOP
  PERFORM fn_otp_issue('00000000-0000-0000-0000-0000000000b3','password_reset',sha256(convert_to('c'||i,'UTF8')));
  UPDATE otp_challenges SET created_at = created_at - interval '2 minutes', expires_at = expires_at - interval '2 minutes' WHERE user_id='00000000-0000-0000-0000-0000000000b3';
END LOOP; END $$;
SELECT t.assert(fn_otp_issue('00000000-0000-0000-0000-0000000000b3','password_reset',t.h('c6'))='limit', 'batas 5 permintaan OTP per jam ditegakkan (anti spam email)');
SELECT t.assert(EXISTS(SELECT 1 FROM audit_logs WHERE action IN ('OTP_LOCKED','OTP_FAILED')) AND EXISTS(SELECT 1 FROM audit_logs WHERE action='PASSWORD_SET'), 'audit mencatat OTP gagal/terkunci & set password');
SELECT t.assert(NOT EXISTS(SELECT 1 FROM audit_logs WHERE details::text LIKE '%654321%' OR details::text LIKE '%123456%'), 'audit tidak memuat kode OTP');

-- sebagai aplikasi
SET ROLE complex_app;
RESET app.user_id;
SELECT t.fails('app tidak bisa SELECT otp_challenges (hash OTP tertutup)', $q$SELECT * FROM otp_challenges$q$, 'permission denied');
SELECT t.fails('app tidak bisa SELECT auth_tokens', $q$SELECT * FROM auth_tokens$q$, 'permission denied');
SELECT t.fails('app tidak bisa mencetak tiket sendiri (INSERT auth_tokens)',
  $q$INSERT INTO auth_tokens(user_id,purpose,token_hash,expires_at) VALUES('00000000-0000-0000-0000-0000000000b1','password_reset',sha256('x'::bytea),now()+interval '5 minutes')$q$, 'permission denied');
SELECT t.fails('app tidak bisa menandai akun aktif lewat UPDATE',
  $q$UPDATE users SET activated_at=now() WHERE id='00000000-0000-0000-0000-0000000000b3'$q$, 'permission denied');
SELECT t.works('app bisa memanggil fn_otp_issue (jalur resmi)', $q$SELECT fn_otp_issue('00000000-0000-0000-0000-0000000000b2','password_reset',sha256('q'::bytea))$q$);
SELECT t.fails('non-admin tidak bisa fn_admin_reset_password',
  $q$SELECT fn_admin_reset_password('00000000-0000-0000-0000-0000000000b3','$argon2id$v=19$m=19456,t=2,p=1$t$t')$q$, 'Hanya admin');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b3',false);
SELECT t.fails('warga (sesi sah) tetap tidak bisa fn_admin_reset_password',
  $q$SELECT fn_admin_reset_password('00000000-0000-0000-0000-0000000000b1','$argon2id$v=19$m=19456,t=2,p=1$t$t')$q$, 'Hanya admin');
SELECT t.fails('warga tidak bisa anonimkan akun', $q$SELECT anonymize_user('00000000-0000-0000-0000-0000000000b1')$q$, 'Hanya admin');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.works('admin mereset password warga (jadi password sementara + aktivasi ulang)',
  $q$SELECT fn_admin_reset_password('00000000-0000-0000-0000-0000000000b1','$argon2id$v=19$m=19456,t=2,p=1$tmp$tmp')$q$);
SELECT t.fails('admin tidak bisa mereset password ADMIN lain lewat fungsi ini',
  $q$SELECT fn_admin_reset_password('00000000-0000-0000-0000-0000000000a1','$argon2id$v=19$m=19456,t=2,p=1$tmp$tmp')$q$, 'tidak ditemukan');
SELECT t.works('admin (via app) mendaftarkan warga: activated_at dipaksa NULL walau dicoba diisi',
  $q$INSERT INTO users(email,full_name,phone,unit_id,password_hash,activated_at,created_by) VALUES('licik@complex.test','Warga Licik','6281200000077',(SELECT min(id) FROM units),'$argon2id$v=19$m=19456,t=2,p=1$z$z',now(),'00000000-0000-0000-0000-0000000000a1')$q$);
SELECT t.assert((SELECT activated_at IS NULL FROM users WHERE email='licik@complex.test'), 'aplikasi tidak bisa melompati OTP lewat INSERT akun aktif');
RESET app.user_id;
RESET ROLE;
SELECT t.assert((SELECT activated_at IS NULL AND activation_expires_at > now() FROM users WHERE id='00000000-0000-0000-0000-0000000000b1'), 'setelah reset admin: budi wajib aktivasi ulang, batas 7 hari');
SELECT t.assert((SELECT count(*) FROM audit_logs WHERE action='PASSWORD_RESET_BY_ADMIN')=1, 'reset oleh admin tercatat di audit');


\echo '=== K. Tamu tanpa akun: sesi anonim, Lapor Tamu 24 jam, anti-spam, beranda per peran ==='
RESET ROLE; RESET app.user_id;
SELECT id AS blk1 FROM blocks WHERE name='Jati 1' \gset
SELECT id AS blk2 FROM blocks WHERE name='Jati 2' \gset
UPDATE users SET activated_at = now() WHERE id='00000000-0000-0000-0000-0000000000b1';   -- budi sempat di-reset admin pada bagian J
SELECT t.assert(NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type ty ON ty.oid=e.enumtypid WHERE ty.typname='user_role' AND e.enumlabel='guest'), 'tamu bukan role akun (user_role hanya admin & warga)');
INSERT INTO announcements(category,title,body,created_by) VALUES
 ('komplek','Kerja Bakti Minggu','Semua warga diharapkan hadir.','00000000-0000-0000-0000-0000000000a1'),
 ('pengurus','Rapat Internal Pengurus','Hanya untuk pengurus.','00000000-0000-0000-0000-0000000000a1');

SET ROLE complex_app;
RESET app.user_id;
-- mulai sesi
SELECT t.assert(fn_guest_session_start(t.h('tokA'),'10.9.0.1','ua')='ok', 'sesi tamu dimulai tanpa akun/admin');
SELECT t.assert(fn_guest_session_start(t.h('tokA'),'10.9.0.1','ua')='invalid', 'token yang sama tidak bisa dipakai membuat sesi lagi');
SELECT t.assert(fn_guest_session_start(sha256(convert_to('pendek','UTF8'))::bytea || '\x00'::bytea,'10.9.0.1')='invalid', 'token dengan panjang tidak valid ditolak');
DO $$ BEGIN FOR i IN 1..20 LOOP PERFORM fn_guest_session_start(sha256(convert_to('limit'||i,'UTF8')),'10.9.0.9'); END LOOP; END $$;
SELECT t.assert(fn_guest_session_start(t.h('limit21'),'10.9.0.9')='limit', 'maks 20 sesi tamu baru per IP per jam (anti banjir)');
SELECT t.assert(fn_guest_session_start(t.h('tokB'),'10.9.0.2')='ok' AND fn_guest_session_start(t.h('tokC'),'10.9.0.3')='ok'
                AND fn_guest_session_start(t.h('tokD'),'10.9.0.1')='ok' AND fn_guest_session_start(t.h('tokE'),'10.9.0.1')='ok'
                AND fn_guest_session_start(t.h('tokF'),'10.9.0.1')='ok' AND fn_guest_session_start(t.h('tokG'),'10.9.0.4')='ok', 'sesi tamu lain dimulai');

-- beranda tamu
SELECT t.assert(fn_guest_home(t.h('tokA')) IS NOT NULL AND fn_guest_home(t.h('tidak-ada')) IS NULL, 'beranda tamu: sesi valid dikenali, token palsu NULL');
SELECT t.assert((fn_guest_home(t.h('tokA'))->>'landing')='beranda_tamu' AND (fn_guest_home(t.h('tokA'))->>'primary_action')='lapor_tamu'
                AND jsonb_array_length(fn_guest_home(t.h('tokA'))->'blocks')=7, 'beranda tamu: tombol utama lapor_tamu + daftar 7 blok');
SELECT t.assert(EXISTS (SELECT 1 FROM jsonb_array_elements(fn_guest_home(t.h('tokA'))->'announcements') a WHERE a->>'title'='Kerja Bakti Minggu')
                AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(fn_guest_home(t.h('tokA'))->'announcements') a WHERE a->>'title'='Rapat Internal Pengurus'), 'tamu melihat berita komplek, bukan pengumuman kategori pengurus');
SELECT t.assert(NOT (fn_guest_home(t.h('tokA')) ? 'events') AND NOT (fn_guest_home(t.h('tokA')) ? 'user'), 'beranda tamu tanpa acara dan tanpa data pengguna');

-- tidak ada jalur lain untuk tamu
SELECT t.assert((SELECT count(*) FROM announcements)=0 AND (SELECT count(*) FROM reports)=0 AND (SELECT count(*) FROM guest_visits)=0
                AND (SELECT count(*) FROM units)=0 AND (SELECT count(*) FROM posts)=0, 'tanpa akun/user_id: tidak ada tabel bisnis yang terbaca langsung');
SELECT t.fails('app tidak bisa membaca guest_sessions', $q$SELECT * FROM guest_sessions$q$, 'permission denied');
SELECT t.fails('app tidak bisa menulis guest_sessions', $q$INSERT INTO guest_sessions(token_hash) VALUES (sha256('x'::bytea))$q$, 'permission denied');
SELECT t.fails('INSERT langsung ke guest_visits tanpa akun ditolak (RLS)',
  $q$INSERT INTO guest_visits(guest_session_id,visitor_name,visitor_address,host_block_id,host_house,purpose) VALUES (gen_random_uuid(),'Palsu','Jl. X 1',1,'1','Iseng')$q$, 'row-level security');

-- Lapor Tamu
SELECT result AS resa, visit_id AS vida FROM fn_guest_report_create(t.h('tokA'),'Tamu Contoh','Jl. Mawar 3, Bekasi',:blk1::smallint,'52','Pak Budi','Silaturahmi keluarga','6281200000099','b 1234 xyz',now(),'10.9.0.1') \gset
SELECT t.assert(:'resa'='ok', 'tamu mengisi form: nama, alamat, blok & rumah tujuan, warga tujuan, keperluan');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokA'),'Tamu Contoh','Jl. Mawar 3',:blk1::smallint,'52',NULL,'Lagi',NULL,NULL,now(),'10.9.0.1'))='active_exists', 'satu sesi tamu hanya boleh punya satu laporan aktif');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokB'),'X','Jl',:blk1::smallint,'52',NULL,'Lagi',NULL,NULL,now(),'10.9.0.2'))='invalid', 'input tidak valid (nama 1 huruf, alamat terlalu pendek) -> invalid');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokB'),'Tamu B','Jl. Anggrek 5',:blk1::smallint,'52',NULL,'Lagi',NULL,NULL,now()-interval '5 hours','10.9.0.2'))='invalid', 'waktu kunjungan 5 jam lalu ditolak');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokB'),'Tamu B','Jl. Anggrek 5',99::smallint,'52',NULL,'Lagi',NULL,NULL,now(),'10.9.0.2'))='invalid', 'blok tidak ada -> invalid');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokB'),'Tamu B','Jl. Anggrek 5',:blk1::smallint,'52',NULL,'Lagi','08123abc',NULL,now(),'10.9.0.2'))='invalid', 'nomor telepon tidak valid -> invalid');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tidak-ada'),'Tamu Z','Jl. Z 1',:blk1::smallint,'52',NULL,'Lagi',NULL,NULL,now(),'10.9.0.5'))='no_session', 'tanpa sesi tamu yang sah -> no_session');
SELECT result AS resc, visit_id AS vidc FROM fn_guest_report_create(t.h('tokC'),'Tamu C','Jl. Dahlia 8, Depok',:blk1::smallint,'999',NULL,'Antar paket besar','','',now(),'10.9.0.3') \gset
SELECT t.assert(:'resc'='ok', 'rumah yang tidak terdaftar tetap diterima (host_unit_id kosong, admin yang menilai)');
SELECT result AS resd, visit_id AS vidd FROM fn_guest_report_create(t.h('tokD'),'Tamu D','Jl. Kenanga 2',:blk2::smallint,' 15 ','Ibu Sari','Kunjungan','', '',now(),'10.9.0.1') \gset
SELECT t.assert(:'resd'='ok', 'nomor rumah dinormalisasi (spasi dibuang)');
SELECT result AS rese, visit_id AS vide FROM fn_guest_report_create(t.h('tokE'),'Tamu E','Jl. Melati 4',:blk1::smallint,'52',NULL,'Servis AC','','',now(),'10.9.0.1') \gset
SELECT t.assert(:'rese'='ok', 'laporan ke-3 dari IP yang sama dalam 1 jam masih diterima');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokF'),'Tamu F','Jl. Cempaka 6',:blk1::smallint,'52',NULL,'Lagi lagi',NULL,NULL,now(),'10.9.0.1'))='limit', 'laporan ke-4 dari IP yang sama dalam 1 jam ditolak (anti spam)');

-- akhiri laporan: hanya milik sesi sendiri
SELECT t.assert(fn_guest_report_end(t.h('tokB'),:'vida',  'selesai')='not_found', 'sesi lain tidak bisa mengakhiri laporan orang lain');
SELECT t.assert(fn_guest_report_end(t.h('tidak-ada'),:'vida','selesai')='no_session', 'tanpa sesi sah tidak bisa mengakhiri laporan');
SELECT t.assert(fn_guest_report_end(t.h('tokG'),:'vida','aktif')='invalid', 'status tujuan harus selesai/dibatalkan');

-- sisi warga & admin
RESET ROLE; RESET app.user_id; SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert((SELECT count(*) FROM v_guest_visits WHERE from_guest)=2 AND (SELECT bool_and(host_house='52') FROM v_guest_visits), 'budi melihat 2 laporan tamu untuk rumahnya (Tamu Contoh, Tamu E), bukan yang lain');
SELECT t.assert((fn_home()->>'landing')='beranda_warga' AND (fn_home()->'stats'->>'guests_at_my_unit')::int=2 AND NOT ((fn_home()->'stats') ? 'reports_new')
                AND (fn_home()->'stats') ? 'my_unpaid_dues', 'beranda warga: 2 tamu di rumahnya, tanpa statistik admin');
SELECT t.fails('warga tidak bisa membaca guest_sessions', $q$SELECT * FROM guest_sessions$q$, 'permission denied');
UPDATE guest_visits SET status='dibatalkan' WHERE id = :'vida';
SELECT t.fails('warga tidak bisa mengubah masa berlaku laporan tamu', $q$UPDATE guest_visits SET valid_until = valid_until + interval '48 hours'$q$, 'permission denied');
SELECT t.fails('warga tidak bisa membuat laporan seolah dari sesi tamu',
  $q$INSERT INTO guest_visits(guest_session_id,visitor_name,visitor_address,host_unit_id,purpose) VALUES (gen_random_uuid(),'Palsu','Jl. X 1',(SELECT unit_id FROM users WHERE id='00000000-0000-0000-0000-0000000000b1'),'Iseng')$q$, 'row-level security');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b2',false);
SELECT t.assert((SELECT count(*) FROM v_guest_visits)=1 AND (SELECT visitor_name FROM v_guest_visits)='Tamu D', 'sari hanya melihat tamu rumahnya (Tamu D)');
SELECT t.works('sari melapor tamunya sendiri (jalur warga)',
  $q$INSERT INTO guest_visits(reporter_id,visitor_name,visitor_address,host_unit_id,purpose) VALUES('00000000-0000-0000-0000-0000000000b2','Ibu Sari','Jl. Kenanga 9, Depok',(SELECT unit_id FROM users WHERE id='00000000-0000-0000-0000-0000000000b2'),'Kunjungan keluarga')$q$);
SELECT t.fails('sari tidak bisa melapor tamu untuk rumah budi',
  $q$INSERT INTO guest_visits(reporter_id,visitor_name,visitor_address,host_unit_id,purpose) VALUES('00000000-0000-0000-0000-0000000000b2','X Palsu','Jl. X 1',(SELECT unit_id FROM users WHERE id='00000000-0000-0000-0000-0000000000b1'),'Iseng')$q$, 'rumahnya sendiri');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.assert((SELECT count(*) FROM v_guest_visits)=5 AND (SELECT count(*) FROM v_guest_visits WHERE from_guest)=4, 'admin melihat semua laporan tamu (4 dari sesi tamu + 1 dari warga)');
SELECT t.assert((fn_home()->>'landing')='beranda_admin' AND (fn_home()->'stats') ? 'reports_new' AND (fn_home()->'stats'->>'guests_active')::int=5, 'beranda admin: 5 tamu aktif + statistik pengelola');
SELECT t.assert((SELECT status FROM v_guest_visits WHERE host_house='52' AND visitor_name='Tamu Contoh')='aktif', 'warga yang bukan pelapor tidak bisa membatalkan laporan tamu (tetap aktif)');
RESET app.user_id;
SELECT t.assert(fn_home() IS NULL, 'tanpa sesi akun: fn_home NULL');
SELECT t.assert(fn_guest_report_end(t.h('tokA'),:'vida','selesai')='ok', 'tamu mengakhiri laporannya sendiri');
SELECT t.assert(fn_guest_report_end(t.h('tokA'),:'vida','dibatalkan')='not_found', 'laporan yang sudah selesai tidak bisa diubah lagi');
SELECT t.assert((fn_guest_home(t.h('tokA'))->'my_reports'->0->>'status')='selesai' AND NOT (fn_guest_home(t.h('tokA'))->'my_reports'->0->>'is_active')::boolean, 'beranda tamu menampilkan status laporannya (selesai)');
SELECT t.assert(jsonb_array_length(fn_guest_home(t.h('tokB'))->'my_reports')=0, 'tamu hanya melihat laporan sesinya sendiri');

-- fakta di DB (dibaca sebagai pemilik)
RESET ROLE;
SELECT t.assert((SELECT valid_until = visit_start + interval '24 hours' AND host_unit_id IS NOT NULL AND host_name='Pak Budi' AND vehicle_plate='B 1234 XYZ' AND ip='10.9.0.1' AND reporter_id IS NULL AND ended_at IS NOT NULL FROM guest_visits WHERE id=:'vida'), 'masa berlaku dihitung DB (24 jam), rumah dicocokkan, plat dinormalisasi, IP tercatat');
SELECT t.assert((SELECT host_unit_id IS NULL AND host_house='999' FROM guest_visits WHERE id=:'vidc') AND (SELECT host_unit_id IS NOT NULL AND host_house='15' FROM guest_visits WHERE id=:'vidd'), 'rumah tak terdaftar: host_unit_id NULL; nomor " 15 " dinormalisasi jadi 15');
SELECT t.assert((SELECT expires_at - created_at = interval '24 hours' FROM guest_sessions WHERE token_hash=t.h('tokA')), 'sesi tamu berlaku tepat 24 jam');
SELECT t.assert(EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.source_key='guest-visit:'||:'vida' AND nr.user_id='00000000-0000-0000-0000-0000000000a1'), 'admin dinotifikasi saat tamu melapor');
SELECT t.assert(EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.title='Tamu untuk rumah Anda' AND nr.user_id='00000000-0000-0000-0000-0000000000b1')
                AND EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.title='Tamu untuk rumah Anda' AND nr.user_id='00000000-0000-0000-0000-0000000000b2'), 'penghuni rumah tujuan (budi, sari) dinotifikasi');
SELECT t.assert((SELECT count(*) FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.source_key LIKE 'guest-visit:'||:'vidc'||'%')=(SELECT count(*) FROM users WHERE role='admin' AND status='aktif'), 'rumah tak terdaftar: hanya admin yang dinotifikasi');

-- kedaluwarsa & pembersihan (time travel)
UPDATE guest_sessions SET created_at = created_at - interval '2 days', expires_at = expires_at - interval '2 days' WHERE token_hash = t.h('tokG');
SET ROLE complex_app;
SELECT t.assert(fn_guest_home(t.h('tokG')) IS NULL, 'sesi tamu kedaluwarsa: beranda NULL (cookie habis)');
SELECT t.assert((SELECT result FROM fn_guest_report_create(t.h('tokG'),'Tamu G','Jl. Ketapang 7',:blk1::smallint,'52',NULL,'Terlambat',NULL,NULL,now(),'10.9.0.4'))='no_session', 'sesi kedaluwarsa tidak bisa membuat laporan');
RESET ROLE;
UPDATE guest_sessions SET created_at = created_at - interval '8 days', expires_at = expires_at - interval '8 days' WHERE token_hash = t.h('tokG');
ALTER TABLE guest_visits DISABLE TRIGGER guest_visits_before; ALTER TABLE guest_visits DISABLE TRIGGER audit_guest_visits;
UPDATE guest_visits SET created_at = now() - interval '40 days' WHERE id = :'vide';
ALTER TABLE guest_visits ENABLE TRIGGER guest_visits_before; ALTER TABLE guest_visits ENABLE TRIGGER audit_guest_visits;
SELECT fn_purge_expired();
SELECT t.assert(NOT EXISTS (SELECT 1 FROM guest_sessions WHERE token_hash=t.h('tokG')) AND EXISTS (SELECT 1 FROM guest_sessions WHERE token_hash=t.h('tokA')), 'purge: sesi tamu lama dibuang, sesi baru tetap');
SELECT t.assert((SELECT ip IS NULL FROM guest_visits WHERE id=:'vide') AND (SELECT ip IS NOT NULL FROM guest_visits WHERE id=:'vidd'), 'purge: IP pada laporan > 30 hari dihapus, laporan tetap ada');
RESET app.user_id; RESET ROLE;

\echo '=== I. Anonimisasi ==='
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT anonymize_user('00000000-0000-0000-0000-0000000000b2');
RESET app.user_id;
SELECT t.assert((SELECT email LIKE 'removed-%@anonymized.invalid' AND phone IS NULL AND status='nonaktif' AND full_name='Warga Nonaktif' FROM users WHERE id='00000000-0000-0000-0000-0000000000b2'), 'data pribadi dianonimkan');
SELECT t.assert((SELECT count(*) FROM reports WHERE reporter_id='00000000-0000-0000-0000-0000000000b2')>0, 'riwayat laporan tetap utuh setelah anonimisasi');
