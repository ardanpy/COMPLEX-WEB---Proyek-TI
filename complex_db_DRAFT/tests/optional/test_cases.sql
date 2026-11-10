-- Tes OPSIONAL kasus keamanan + SIGAP (db/optional/10b_security_cases.sql). Dijalankan oleh tests/optional/run_cases.sh.
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

\echo '=== Persiapan ==='
RESET ROLE; RESET app.user_id;
INSERT INTO users(id,email,full_name,phone,role,password_hash,activated_at,created_by) VALUES
 ('00000000-0000-0000-0000-0000000000e1','satpam1@complex.test','Satpam Satu','6281300000001','security','$argon2id$v=19$m=19456,t=2,p=1$a$b',now(),'00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000000e2','satpam2@complex.test','Satpam Dua','6281300000002','security','$argon2id$v=19$m=19456,t=2,p=1$a$b',now(),'00000000-0000-0000-0000-0000000000a1');
SET ROLE complex_app;

\echo '=== P3. Kasus keamanan & progres ==='
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e1',false);
INSERT INTO security_cases(title,description,location_text,priority,status,created_by) VALUES ('Motor mencurigakan di Jati 3','Terlihat berputar 3x','Gerbang Jati 3','tinggi','selesai','00000000-0000-0000-0000-0000000000e1') RETURNING id AS c1 \gset
SELECT t.assert((SELECT code ~ '^KS-[0-9]{4}-[0-9]{4}$' AND status='baru' AND assigned_to='00000000-0000-0000-0000-0000000000e1' FROM security_cases WHERE id=:'c1'), 'kasus: kode otomatis, status dipaksa baru, ditugaskan ke pembuatnya');
SELECT t.fails('lompat status baru -> selesai ditolak',
  $q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES((SELECT id FROM security_cases LIMIT 1),'00000000-0000-0000-0000-0000000000e1','selesai','curang')$q$, 'Transisi');
SELECT t.works('progres: ditangani (dengan foto bukti)', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note,photo_key) VALUES(%L,'00000000-0000-0000-0000-0000000000e1','ditangani','Menuju lokasi','88888888-8888-8888-8888-888888888888.jpg')$q$, :'c1'));
SELECT t.assert((SELECT status='ditangani' FROM security_cases WHERE id=:'c1'), 'status kasus bergerak lewat progres');
SELECT t.works('progres: menunggu tindak lanjut', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES(%L,'00000000-0000-0000-0000-0000000000e1','menunggu_tindak_lanjut','Menunggu CCTV pengelola')$q$, :'c1'));
SELECT t.works('progres: selesai', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES(%L,'00000000-0000-0000-0000-0000000000e1','selesai','Pelaku teridentifikasi, sudah diamankan')$q$, :'c1'));
SELECT t.fails('security tidak bisa menutup kasus', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES(%L,'00000000-0000-0000-0000-0000000000e1','ditutup','tutup')$q$, :'c1'), 'Hanya admin');
SELECT t.fails('security tidak bisa mengubah status kasus langsung', $q$UPDATE security_cases SET status='ditutup'$q$, 'permission denied');
SELECT t.fails('linimasa append-only: UPDATE ditolak', $q$UPDATE security_case_updates SET note='diubah'$q$, 'permission denied');
SELECT t.fails('linimasa append-only: DELETE ditolak', $q$DELETE FROM security_case_updates$q$, 'permission denied');
SELECT t.fails('security tidak bisa mengaku sebagai penulis lain', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES(%L,'00000000-0000-0000-0000-0000000000e2','ditangani','palsu')$q$, :'c1'), 'row-level security');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert((SELECT count(*) FROM security_cases)=0 AND (SELECT count(*) FROM security_case_updates)=0, 'warga tidak melihat kasus/progres internal');
SELECT t.fails('warga tidak bisa membuka kasus', $q$INSERT INTO security_cases(title,created_by) VALUES('Iseng','00000000-0000-0000-0000-0000000000b1')$q$, 'row-level security');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000a1',false);
SELECT t.assert((SELECT count(*) FROM security_case_updates WHERE case_id=:'c1')=3, 'admin melihat linimasa 3 pembaruan');
SELECT t.fails('admin tidak bisa menugaskan kasus ke warga', format($q$UPDATE security_cases SET assigned_to='00000000-0000-0000-0000-0000000000b1' WHERE id=%L$q$, :'c1'), 'security yang aktif');
SELECT t.works('admin menugaskan ulang kasus ke security lain', format($q$UPDATE security_cases SET assigned_to='00000000-0000-0000-0000-0000000000e2' WHERE id=%L$q$, :'c1'));
SELECT t.works('admin menutup kasus', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES(%L,'00000000-0000-0000-0000-0000000000a1','ditutup','Terverifikasi, ditutup')$q$, :'c1'));
SELECT t.assert((SELECT status='ditutup' AND closed_at IS NOT NULL FROM security_cases WHERE id=:'c1'), 'kasus ditutup: closed_at terisi');
SELECT t.fails('kasus ditutup tidak bisa diubah lagi', format($q$INSERT INTO security_case_updates(case_id,author_id,status_after,note) VALUES(%L,'00000000-0000-0000-0000-0000000000a1','ditangani','buka lagi')$q$, :'c1'), 'Transisi');
RESET ROLE;
SELECT t.assert(EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.title='Kasus keamanan baru' AND nr.user_id='00000000-0000-0000-0000-0000000000a1')
            AND EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.title='Kasus keamanan selesai' AND nr.user_id='00000000-0000-0000-0000-0000000000a1'), 'admin dinotifikasi saat kasus baru dan saat selesai');

\echo '=== P4. SIGAP & beranda security ==='
SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
INSERT INTO sigap_alerts(user_id,message) VALUES ('00000000-0000-0000-0000-0000000000b1','Ada orang asing di depan rumah') RETURNING id AS sg1 \gset
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000e1',false);
SELECT t.assert((SELECT count(*) FROM sigap_alerts WHERE id=:'sg1')=1, 'security melihat SIGAP warga');
SELECT t.works('security menerima SIGAP (diterima)', format($q$UPDATE sigap_alerts SET status='diterima' WHERE id=%L$q$, :'sg1'));
SELECT t.assert((SELECT acknowledged_by='00000000-0000-0000-0000-0000000000e1' AND acknowledged_at IS NOT NULL FROM sigap_alerts WHERE id=:'sg1'), 'tercatat siapa yang menerima SIGAP');
SELECT t.works('security membuka kasus dari SIGAP', format($q$INSERT INTO security_cases(title,created_by,sigap_id) VALUES('Orang asing di Jati 1','00000000-0000-0000-0000-0000000000e1',%L)$q$, :'sg1'));
SELECT t.assert((fn_home_security()->>'landing')='beranda_security' AND (fn_home_security()->'stats') ? 'cases_open' AND (fn_home_security()->'stats'->>'sigap_open')::int >= 1
                AND NOT (fn_home_security()::text LIKE '%password%'), 'beranda security: landing, statistik kasus & SIGAP, tanpa data sensitif');
RESET ROLE;
SELECT t.fails('kasus tidak boleh punya dua sumber sekaligus (laporan & SIGAP)',
  format($q$INSERT INTO security_cases(title,created_by,report_id,sigap_id) VALUES('Ganda',%L,(SELECT id FROM reports LIMIT 1),%L)$q$, '00000000-0000-0000-0000-0000000000e1', :'sg1'), 'security_cases_check');
SET ROLE complex_app;
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b1',false);
SELECT t.assert(fn_home_security() IS NULL, 'warga tidak mendapat beranda security (NULL)');
SELECT set_config('app.user_id','00000000-0000-0000-0000-0000000000b3',false);
INSERT INTO sigap_alerts(user_id,message) VALUES ('00000000-0000-0000-0000-0000000000b3','Cek lagi') RETURNING id AS sg2 \gset
SELECT t.fails('warga tidak bisa menerima/menindaklanjuti SIGAP sendiri (hanya boleh membatalkan)', format($q$UPDATE sigap_alerts SET status='diterima' WHERE id=%L$q$, :'sg2'), 'row-level security');
RESET ROLE; RESET app.user_id;
SELECT t.assert(EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.title='SIGAP: peringatan darurat' AND nr.user_id='00000000-0000-0000-0000-0000000000e1')
            AND EXISTS (SELECT 1 FROM notification_recipients nr JOIN notifications n ON n.id=nr.notification_id WHERE n.title='Status SIGAP diperbarui' AND nr.user_id='00000000-0000-0000-0000-0000000000b1'), 'security dinotifikasi saat SIGAP; warga dinotifikasi saat SIGAP diterima');

