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
  = (SELECT count(*) FROM users WHERE status='aktif'), 'pengumuman di-fanout ke seluruh pengguna aktif');
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
SELECT t.fails('app tidak bisa membuat akun ADMIN',
  $q$INSERT INTO users(email,full_name,role,password_hash,created_by) VALUES('hack@t.id','Hack','admin','$2a$06$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','00000000-0000-0000-0000-0000000000a1')$q$, 'admin hanya dapat dibuat');
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

\echo '=== I. Anonimisasi ==='
SELECT anonymize_user('00000000-0000-0000-0000-0000000000b2');
SELECT t.assert((SELECT email LIKE 'removed-%@anonymized.invalid' AND phone IS NULL AND status='nonaktif' AND full_name='Warga Nonaktif' FROM users WHERE id='00000000-0000-0000-0000-0000000000b2'), 'data pribadi dianonimkan');
SELECT t.assert((SELECT count(*) FROM reports WHERE reporter_id='00000000-0000-0000-0000-0000000000b2')>0, 'riwayat laporan tetap utuh setelah anonimisasi');
