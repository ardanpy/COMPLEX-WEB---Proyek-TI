-- Tes role security (FINAL): akun, absen foto, laporan warga untuk security, integrasi. Dijalankan oleh tests/run_security.sh.
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

CREATE FUNCTION t.h(text) RETURNS bytea LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to($1, 'UTF8')) $$;
GRANT EXECUTE ON FUNCTION t.h(text) TO complex_app;

\echo '=== P1. Akun security (hanya dibuat admin, tanpa rumah) ==='
RESET ROLE; RESET app.user_id;
INSERT INTO users(id,email,full_name,phone,role,password_hash,activated_at,created_by) VALUES
 ('00000000-0000-0000-0000-0000000000e1','satpam1@complex.test','Satpam Satu','6281300000001','security','$argon2id$v=19$m=19456,t=2,p=1$a$b',now(),'00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000000e2','satpam2@complex.test','Satpam Dua','6281300000002','security','$argon2id$v=19$m=19456,t=2,p=1$a$b',now(),'00000000-0000-0000-0000-0000000000a1');
SELECT t.assert((SELECT count(*) FROM users WHERE role::text='security')=2 AND (SELECT bool_and(unit_id IS NULL) FROM users WHERE role::text='security'), 'akun security dibuat tanpa rumah');
SELECT t.fails('warga tanpa rumah tetap ditolak',
  $q$INSERT INTO users(email,full_name,password_hash,created_by) VALUES('w0@t.id','Warga Nol','$argon2id$v=19$m=19456,t=2,p=1$a$b','00000000-0000-0000-0000-0000000000a1')$q$, 'warga_wajib_punya_rumah');
SELECT t.fails('security tanpa created_by (admin) ditolak',
  $q$INSERT INTO users(email,full_name,role,password_hash) VALUES('s0@t.id','Satpam Nol','security','$argon2id$v=19$m=19456,t=2,p=1$a$b')$q$, 'warga_wajib_didaftarkan_admin');
SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.fails('sesi warga tidak bisa mendaftarkan akun security',
  $q$INSERT INTO users(email,full_name,role,password_hash,created_by) VALUES('s9@t.id','Satpam Palsu','security','$argon2id$v=19$m=19456,t=2,p=1$a$b','00000000-0000-0000-0000-0000000000a1')$q$, 'Hanya admin');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.works('admin mendaftarkan akun security',
  $q$INSERT INTO users(email,full_name,role,password_hash,created_by) VALUES('satpam3@complex.test','Satpam Tiga','security','$argon2id$v=19$m=19456,t=2,p=1$a$b','00000000-0000-0000-0000-0000000000a1')$q$);
SELECT t.assert((SELECT activated_at IS NULL FROM users WHERE email='satpam3@complex.test'), 'akun security baru wajib aktivasi OTP (activated_at NULL)');
SELECT t.works('admin mereset password akun security (jalur yang sama dengan warga)',
  $q$SELECT fn_admin_reset_password((SELECT id FROM users WHERE email='satpam3@complex.test'),'$argon2id$v=19$m=19456,t=2,p=1$t$t')$q$);
SELECT t.fails('admin tidak bisa mereset password admin lewat fungsi ini',
  $q$SELECT fn_admin_reset_password('00000000-0000-0000-0000-0000000000a1','$argon2id$v=19$m=19456,t=2,p=1$t$t')$q$, 'tidak ditemukan');

\echo '=== P2. Absen dengan foto ==='
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e1',false);
SELECT t.fails('absen masuk tanpa foto ditolak',
  $q$INSERT INTO security_attendance(user_id,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000e1',NULL)$q$, 'null value');
SELECT t.fails('kunci foto bentuk bebas (path traversal) ditolak',
  $q$INSERT INTO security_attendance(user_id,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000e1','../../etc/passwd')$q$, 'check_in_photo_key');
SELECT t.works('absen masuk dengan foto (klien mencoba mengirim jam masuk kemarin)',
  $q$INSERT INTO security_attendance(user_id,check_in_at,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000e1', now()-interval '1 day','11111111-1111-1111-1111-111111111111.jpg')$q$);
SELECT t.assert((SELECT check_in_at > now() - interval '1 minute' FROM security_attendance WHERE user_id='00000000-0000-0000-0000-0000000000e1'), 'jam masuk selalu dari server, bukan dari klien');
SELECT t.fails('tidak boleh absen masuk dua kali tanpa pulang',
  $q$INSERT INTO security_attendance(user_id,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000e1','22222222-2222-2222-2222-222222222222.jpg')$q$, 'security_attendance_one_open');
SELECT t.fails('security tidak bisa absen atas nama rekan',
  $q$INSERT INTO security_attendance(user_id,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000e2','33333333-3333-3333-3333-333333333333.jpg')$q$, 'row-level security');
SELECT t.fails('foto absen masuk tidak bisa diganti', $q$UPDATE security_attendance SET check_in_photo_key='44444444-4444-4444-4444-444444444444.jpg'$q$, 'permission denied');
SELECT t.assert((fn_home_security()->'attendance'->>'on_duty')::boolean, 'beranda security: status bertugas (on_duty)');
SELECT t.works('absen pulang dengan foto', $q$UPDATE security_attendance SET check_out_photo_key='55555555-5555-5555-5555-555555555555.png' WHERE user_id='00000000-0000-0000-0000-0000000000e1' AND check_out_at IS NULL$q$);
SELECT t.assert((SELECT check_out_at IS NOT NULL AND NOT on_duty AND duration_minutes >= 0 FROM v_security_attendance WHERE user_id='00000000-0000-0000-0000-0000000000e1'), 'jam pulang dari server; view menghitung durasi');
SELECT t.fails('absen pulang tidak bisa diubah lagi', $q$UPDATE security_attendance SET note='revisi'$q$, 'sudah tercatat');
SELECT t.works('absen masuk shift berikutnya setelah pulang', $q$INSERT INTO security_attendance(user_id,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000e1','66666666-6666-6666-6666-666666666666.webp')$q$);
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e2',false);
SELECT t.assert((SELECT count(*) FROM security_attendance)=0, 'security lain tidak melihat absen rekan');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert((SELECT count(*) FROM security_attendance)=0, 'warga tidak melihat absen security');
SELECT t.fails('warga tidak bisa absen', $q$INSERT INTO security_attendance(user_id,check_in_photo_key) VALUES('00000000-0000-0000-0000-0000000000b1','77777777-7777-7777-7777-777777777777.jpg')$q$, 'row-level security');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.assert((SELECT count(*) FROM security_attendance)=2, 'admin melihat seluruh absen');


\echo '=== P3. Security melihat laporan warga (hanya baca) ==='
RESET ROLE; RESET app.user_id;
SELECT count(*) AS n_rep FROM reports \gset
SELECT t.assert(:n_rep > 0, 'data demo punya laporan warga untuk diuji');
SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e1',false);
SELECT t.assert((SELECT count(*) FROM v_reports_for_security) = :n_rep, 'security melihat seluruh laporan warga lewat view');
SELECT t.assert((SELECT bool_and(reporter_name IS NOT NULL) FROM v_reports_for_security), 'nama pelapor terbaca walau RLS users hanya baris sendiri');
SELECT t.assert(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='v_reports_for_security' AND column_name IN ('admin_note','reporter_id','handled_by','email','phone')),
  'view tidak memuat admin_note, id pelapor, telepon, atau email');
DO $$
DECLARE n int; blocked boolean := false;
BEGIN
  BEGIN UPDATE reports SET status = 'selesai'; GET DIAGNOSTICS n = ROW_COUNT;
  EXCEPTION WHEN insufficient_privilege THEN blocked := true; n := 0; END;
  IF n = 0 THEN RAISE NOTICE 'PASS  security tidak bisa mengubah status laporan (0 baris terubah%)', CASE WHEN blocked THEN ', ditolak hak akses' ELSE ', disaring RLS' END;
  ELSE RAISE NOTICE 'FAIL  security mengubah % laporan', n; END IF;
END $$;
SELECT t.fails('security tidak bisa membuat laporan atas nama warga',
  $q$INSERT INTO reports(reporter_id,category,title,description,location_text) VALUES('00000000-0000-0000-0000-0000000000b1','keamanan','Palsu','x','Jati 1')$q$, 'row-level security');
SELECT t.fails('security tidak bisa menghapus laporan', $q$DELETE FROM reports$q$, 'permission denied');
SELECT t.assert((fn_home_security()->'stats') ? 'reports_open' AND (fn_home_security()->'stats') ? 'reports_keamanan_new', 'beranda security memuat statistik laporan');
SELECT t.assert(NOT (fn_home_security()::text LIKE '%password%'), 'beranda security tanpa data sensitif');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert((SELECT count(*) FROM v_reports_for_security) = 0, 'warga tidak dapat memakai view khusus security');
SELECT t.assert(fn_home_security() IS NULL, 'warga tidak mendapat beranda security (NULL)');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.assert((SELECT count(*) FROM v_reports_for_security) = :n_rep, 'admin juga dapat memakai view (staff)');
RESET ROLE; RESET app.user_id;

\echo '=== P3b. Satpam mengubah status laporan + log admin + pengetatan role ==='
RESET ROLE; RESET app.user_id;
SELECT id AS rid FROM reports WHERE status = 'dikirim' ORDER BY created_at LIMIT 1 \gset
SELECT reporter_id AS rep_user FROM reports WHERE id = :'rid' \gset
SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e1',false);
SELECT t.assert(fn_security_set_report_status(:'rid', 'dikirim') = 'invalid', 'satpam tidak bisa mengembalikan status ke dikirim');
SELECT t.assert(fn_security_set_report_status(gen_random_uuid(), 'diproses') = 'not_found', 'laporan tak ada -> not_found');
SELECT t.assert(fn_security_set_report_status(:'rid', 'diproses', 'Sudah dicek di lokasi') = 'ok', 'satpam mengubah dikirim -> diproses');
SELECT t.assert(fn_security_set_report_status(:'rid', 'diproses') = 'unchanged', 'status sama -> unchanged');
SELECT t.assert((SELECT status = 'diproses' AND handled_by = '00000000-0000-0000-0000-0000000000e1' FROM reports WHERE id = :'rid'), 'status berubah dan handled_by = satpam');
SELECT t.assert(fn_security_set_report_status(:'rid', 'selesai', 'Masalah beres') = 'ok', 'satpam menyelesaikan laporan');
SELECT t.assert(fn_security_set_report_status(:'rid', 'diproses') = 'closed', 'satpam tidak membuka ulang laporan selesai');
SELECT t.assert((SELECT resolved_at IS NOT NULL FROM reports WHERE id = :'rid'), 'resolved_at terisi saat selesai');
DO $$
DECLARE n int; blocked boolean := false;
BEGIN
  BEGIN UPDATE reports SET admin_note = 'dipalsukan'; GET DIAGNOSTICS n = ROW_COUNT;
  EXCEPTION WHEN insufficient_privilege THEN blocked := true; n := 0; END;
  IF n = 0 THEN RAISE NOTICE 'PASS  satpam tidak bisa mengubah admin_note lewat tabel';
  ELSE RAISE NOTICE 'FAIL  satpam mengubah % baris reports langsung', n; END IF;
END $$;
SELECT t.assert((SELECT count(*) FROM v_report_status_log) = 0, 'satpam tidak membaca log admin');
SELECT set_config('app.user_id', :'rep_user', false);
SELECT t.assert(fn_security_set_report_status(:'rid', 'ditolak') = 'forbidden', 'warga tidak bisa memakai fungsi satpam');
SELECT t.assert((SELECT count(*) FROM v_report_status_log) = 0, 'warga tidak membaca log admin');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.assert((SELECT count(*) FROM v_report_status_log WHERE report_id = :'rid' AND actor_role = 'security'
                   AND actor_name = 'Satpam Satu' AND note IN ('Sudah dicek di lokasi','Masalah beres')) = 2,
  'admin melihat log: pelaku satpam, catatan, dari-ke status');
SELECT t.assert((SELECT count(*) FROM audit_logs WHERE entity = 'reports' AND entity_id = :'rid' AND actor_id = '00000000-0000-0000-0000-0000000000e1') >= 2,
  'audit_logs mencatat perubahan oleh satpam (terlihat admin)');
RESET ROLE;
SELECT t.assert(EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id = nr.notification_id
                         WHERE n.title = 'Status laporan diperbarui' AND nr.user_id = :'rep_user'), 'warga pelapor dinotifikasi saat satpam mengubah status');
SELECT count(*) AS n_posts FROM posts \gset
SELECT t.assert(:n_posts > 0, 'data demo punya postingan komunitas');
SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e1',false);
SELECT t.assert((SELECT count(*) FROM posts) = 0 AND (SELECT count(*) FROM post_comments) = 0, 'satpam tidak membaca komunitas');
SELECT t.assert((SELECT count(*) FROM v_community_members) = 0 AND (SELECT count(*) FROM v_post_stats) = 0, 'satpam tidak membaca daftar anggota/statistik komunitas');
SELECT t.fails('satpam tidak bisa memposting di komunitas', $q$INSERT INTO posts(author_id, body) VALUES('00000000-0000-0000-0000-0000000000e1','halo')$q$, 'row-level security');
SELECT t.fails('satpam tidak bisa menekan SIGAP', $q$INSERT INTO sigap_alerts(user_id) VALUES('00000000-0000-0000-0000-0000000000e1')$q$, 'row-level security');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert((SELECT count(*) FROM v_community_members WHERE role::text = 'security') = 0 AND (SELECT count(*) FROM v_community_members) > 0, 'warga melihat anggota, tanpa akun security');
RESET ROLE; RESET app.user_id;

\echo '=== P4. Integrasi tambahan (tamu & slot petugas) ==='
RESET ROLE; RESET app.user_id;
SELECT t.assert((SELECT count(*) FROM pg_policies WHERE tablename='guest_visits' AND policyname='gv_sel' AND qual LIKE '%app_is_security%')=1, 'policy gv_sel mencakup security');
SELECT t.fails('slot petugas hanya untuk akun security', $q$UPDATE security_guards SET user_id='00000000-0000-0000-0000-0000000000b1' WHERE slot=1$q$, 'ber-role security');

\echo '=== P5. Kunci akun lewat jalur aplikasi (perbaikan 11) ==='
RESET ROLE; RESET app.user_id;
UPDATE users SET failed_login_count = 0, locked_until = NULL WHERE id = '00000000-0000-0000-0000-0000000000b2';
SET ROLE complex_app;
SELECT set_config('app.user_id', '', false);   -- pra-login: tanpa pengguna
SELECT fn_login_failed('00000000-0000-0000-0000-0000000000b2', 'x@complex.test', '10.9.9.9') FROM generate_series(1,5);
RESET ROLE;
SELECT t.assert((SELECT failed_login_count = 5 AND locked_until > now() FROM users WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  'sebagai complex_app tanpa sesi: 5 gagal login mengunci akun 15 menit');
SET ROLE complex_app;
SELECT fn_login_succeeded('00000000-0000-0000-0000-0000000000b2', 'x@complex.test', '10.9.9.9');
RESET ROLE;
SELECT t.assert((SELECT failed_login_count = 0 AND locked_until IS NULL AND last_login_at IS NOT NULL FROM users WHERE id = '00000000-0000-0000-0000-0000000000b2'),
  'sebagai complex_app tanpa sesi: login sukses mereset kunci');
