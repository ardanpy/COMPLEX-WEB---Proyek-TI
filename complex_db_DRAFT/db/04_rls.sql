-- =====================================================================
-- COMPLEX — 04: Row Level Security (pertahanan berlapis terhadap bug otorisasi / IDOR)
-- Backend wajib set per transaksi:  SELECT set_config('app.user_id', '<uuid dari sesi server>', true);
-- CATATAN JUJUR: RLS berbasis variabel sesi melindungi dari BUG aplikasi (mis. lupa cek pemilik data),
-- bukan dari penyerang yang sudah bisa menjalankan SQL bebas. Perlindungan SQL injection yang utama
-- tetap: query terparameter + hak akses minimal (03) + constraint (02).
-- Tabel auth (users, sessions, auth_tokens, login_attempts) sengaja tanpa RLS karena dipakai sebelum login;
-- dilindungi oleh GRANT per kolom.
-- =====================================================================
SET client_min_messages = warning;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['blocks','units','announcements','events','notifications','notification_recipients',
    'reports','report_status_history','facility_requests','security_guards','security_shift_config',
    'sigap_alerts','dues_bills','posts','post_media','post_likes','post_comments','audit_logs']
  LOOP EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t); END LOOP;
END $$;

-- referensi & informasi: terbaca semua pengguna login, ditulis admin
CREATE POLICY ref_sel ON blocks FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY ref_ins ON blocks FOR INSERT TO complex_app WITH CHECK (app_is_admin());
CREATE POLICY ref_sel ON units  FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY ref_ins ON units  FOR INSERT TO complex_app WITH CHECK (app_is_admin());
CREATE POLICY ref_upd ON units  FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());

CREATE POLICY ann_sel ON announcements FOR SELECT TO complex_app USING (app_uid() IS NOT NULL AND (deleted_at IS NULL OR app_is_admin()));
CREATE POLICY ann_ins ON announcements FOR INSERT TO complex_app WITH CHECK (app_is_admin() AND created_by = app_uid());
CREATE POLICY ann_upd ON announcements FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY evt_sel ON events FOR SELECT TO complex_app USING (app_uid() IS NOT NULL AND (deleted_at IS NULL OR app_is_admin()));
CREATE POLICY evt_ins ON events FOR INSERT TO complex_app WITH CHECK (app_is_admin() AND created_by = app_uid());
CREATE POLICY evt_upd ON events FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());

CREATE POLICY grd_sel ON security_guards FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY grd_ins ON security_guards FOR INSERT TO complex_app WITH CHECK (app_is_admin());
CREATE POLICY grd_upd ON security_guards FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY shf_sel ON security_shift_config FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY shf_upd ON security_shift_config FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());

-- notifikasi: hanya milik sendiri
CREATE POLICY nr_sel ON notification_recipients FOR SELECT TO complex_app USING (user_id = app_uid());
CREATE POLICY nr_upd ON notification_recipients FOR UPDATE TO complex_app USING (user_id = app_uid()) WITH CHECK (user_id = app_uid());
CREATE POLICY n_sel  ON notifications FOR SELECT TO complex_app
  USING (EXISTS (SELECT 1 FROM notification_recipients r WHERE r.notification_id = notifications.id AND r.user_id = app_uid()));

-- laporan: daftar terlihat semua warga (seperti UI), buat hanya atas nama sendiri, ubah status hanya admin
CREATE POLICY rep_sel ON reports FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY rep_ins ON reports FOR INSERT TO complex_app WITH CHECK (reporter_id = app_uid() AND status = 'dikirim');
CREATE POLICY rep_upd ON reports FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY rh_sel  ON report_status_history FOR SELECT TO complex_app
  USING (app_is_admin() OR EXISTS (SELECT 1 FROM reports r WHERE r.id = report_id AND r.reporter_id = app_uid()));

-- fasilitas: milik sendiri / admin; pemohon hanya boleh membatalkan yang masih menunggu
CREATE POLICY fr_sel ON facility_requests FOR SELECT TO complex_app USING (requester_id = app_uid() OR app_is_admin());
CREATE POLICY fr_ins ON facility_requests FOR INSERT TO complex_app
  WITH CHECK (requester_id = app_uid() AND status = 'menunggu_konfirmasi');
CREATE POLICY fr_upd_admin ON facility_requests FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY fr_upd_owner ON facility_requests FOR UPDATE TO complex_app
  USING (requester_id = app_uid() AND status = 'menunggu_konfirmasi')
  WITH CHECK (requester_id = app_uid() AND status = 'dibatalkan');

-- SIGAP: pengirim & admin. (Mode anonim DINONAKTIFKAN; lihat README sebelum mengaktifkan.)
CREATE POLICY sg_sel ON sigap_alerts FOR SELECT TO complex_app USING (user_id = app_uid() OR app_is_admin());
CREATE POLICY sg_ins ON sigap_alerts FOR INSERT TO complex_app WITH CHECK (user_id = app_uid() AND status = 'terkirim');
CREATE POLICY sg_upd_admin ON sigap_alerts FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY sg_upd_owner ON sigap_alerts FOR UPDATE TO complex_app
  USING (user_id = app_uid() AND status = 'terkirim') WITH CHECK (user_id = app_uid() AND status = 'dibatalkan');

-- iuran: tagihan rumah sendiri / admin
CREATE POLICY db_sel ON dues_bills FOR SELECT TO complex_app
  USING (app_is_admin() OR unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid()));
CREATE POLICY db_ins ON dues_bills FOR INSERT TO complex_app WITH CHECK (app_is_admin());
CREATE POLICY db_upd ON dues_bills FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());

-- komunitas
CREATE POLICY po_sel ON posts FOR SELECT TO complex_app USING (app_uid() IS NOT NULL AND (deleted_at IS NULL OR app_is_admin()));
CREATE POLICY po_ins ON posts FOR INSERT TO complex_app WITH CHECK (author_id = app_uid() AND deleted_at IS NULL);
CREATE POLICY po_upd ON posts FOR UPDATE TO complex_app
  USING (author_id = app_uid() OR app_is_admin())
  WITH CHECK ((author_id = app_uid() OR app_is_admin()) AND (deleted_by IS NULL OR deleted_by = app_uid()));
CREATE POLICY pm_sel ON post_media FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY pm_ins ON post_media FOR INSERT TO complex_app
  WITH CHECK (EXISTS (SELECT 1 FROM posts p WHERE p.id = post_id AND p.author_id = app_uid()));
CREATE POLICY pm_del ON post_media FOR DELETE TO complex_app
  USING (app_is_admin() OR EXISTS (SELECT 1 FROM posts p WHERE p.id = post_id AND p.author_id = app_uid()));
CREATE POLICY pl_sel ON post_likes FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY pl_ins ON post_likes FOR INSERT TO complex_app WITH CHECK (user_id = app_uid());
CREATE POLICY pl_del ON post_likes FOR DELETE TO complex_app USING (user_id = app_uid());
CREATE POLICY pc_sel ON post_comments FOR SELECT TO complex_app USING (app_uid() IS NOT NULL AND (deleted_at IS NULL OR app_is_admin()));
CREATE POLICY pc_ins ON post_comments FOR INSERT TO complex_app WITH CHECK (author_id = app_uid() AND deleted_at IS NULL);
CREATE POLICY pc_upd ON post_comments FOR UPDATE TO complex_app
  USING (author_id = app_uid() OR app_is_admin())
  WITH CHECK ((author_id = app_uid() OR app_is_admin()) AND (deleted_by IS NULL OR deleted_by = app_uid()));

-- audit: hanya admin yang boleh membaca; siapa pun boleh menulis (dipakai fungsi login pra-autentikasi)
CREATE POLICY au_sel ON audit_logs FOR SELECT TO complex_app USING (app_is_admin());
CREATE POLICY au_ins ON audit_logs FOR INSERT TO complex_app WITH CHECK (true);
