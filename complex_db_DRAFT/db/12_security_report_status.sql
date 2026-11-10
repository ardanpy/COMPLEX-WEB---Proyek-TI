-- =====================================================================
-- COMPLEX — 12: satpam boleh mengubah status laporan warga + log lengkap untuk admin + pengetatan hak per role
--
-- A. fn_security_set_report_status: satu-satunya jalur satpam mengubah laporan. Hanya kolom status yang bisa
--    berubah (admin_note/handled_by/isi laporan tak tersentuh). Riwayat (report_status_history) mencatat siapa, dari-ke,
--    catatan satpam, dan waktu server; audit_logs mencatat baris yang berubah. Warga pelapor dinotifikasi (trigger lama).
--    Aturan: satpam tidak membuka ulang laporan yang sudah selesai/ditolak (itu wewenang admin) dan tidak
--    mengembalikan ke 'dikirim'.
-- B. v_report_status_log: log status laporan lengkap (pelaku + role) — hanya admin.
-- C. Audit hak akses per role: role security tadinya lolos kebijakan "app_uid() IS NOT NULL" sehingga bisa membaca/
--    menulis komunitas dan membuat laporan/SIGAP atas namanya. Kini komunitas, pembuatan laporan, dan pembuatan SIGAP
--    hanya untuk anggota (admin/warga); daftar anggota tidak lagi menampilkan security.
-- =====================================================================
SET client_min_messages = warning;

-- ---------- A ----------
CREATE FUNCTION fn_security_set_report_status(p_report uuid, p_status report_status, p_note text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE cur report_status;
BEGIN
  IF NOT app_is_security() THEN RETURN 'forbidden'; END IF;
  IF p_note IS NOT NULL AND char_length(p_note) > 1000 THEN RETURN 'invalid'; END IF;
  IF p_status = 'dikirim' THEN RETURN 'invalid'; END IF;
  SELECT status INTO cur FROM reports WHERE id = p_report FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  IF cur IN ('selesai', 'ditolak') THEN RETURN 'closed'; END IF;
  IF cur = p_status THEN RETURN 'unchanged'; END IF;
  UPDATE reports SET status = p_status WHERE id = p_report;                -- trigger: resolved_at, handled_by, riwayat, notifikasi
  UPDATE report_status_history SET note = nullif(btrim(p_note), '')
   WHERE id = (SELECT max(id) FROM report_status_history WHERE report_id = p_report);   -- catatan satpam (bukan admin_note)
  RETURN 'ok';
END $$;
REVOKE ALL ON FUNCTION fn_security_set_report_status(uuid, report_status, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_security_set_report_status(uuid, report_status, text) TO complex_app;

-- ---------- B ----------
CREATE VIEW v_report_status_log WITH (security_invoker = true, security_barrier = true) AS
  SELECT h.id, h.report_id, r.title, r.category, h.from_status, h.to_status,
         h.changed_by, u.full_name AS actor_name, u.role AS actor_role, h.note, h.changed_at
    FROM report_status_history h
    JOIN reports r ON r.id = h.report_id
    LEFT JOIN users u ON u.id = h.changed_by
   WHERE app_is_admin();
GRANT SELECT ON v_report_status_log TO complex_app;

-- ---------- C ----------
DROP POLICY po_sel ON posts;         CREATE POLICY po_sel ON posts FOR SELECT TO complex_app
  USING (app_is_member() AND (deleted_at IS NULL OR app_is_admin()));
DROP POLICY po_ins ON posts;         CREATE POLICY po_ins ON posts FOR INSERT TO complex_app
  WITH CHECK (app_is_member() AND author_id = app_uid() AND deleted_at IS NULL);
DROP POLICY pm_sel ON post_media;    CREATE POLICY pm_sel ON post_media FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY pl_sel ON post_likes;    CREATE POLICY pl_sel ON post_likes FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY pl_ins ON post_likes;    CREATE POLICY pl_ins ON post_likes FOR INSERT TO complex_app WITH CHECK (app_is_member() AND user_id = app_uid());
DROP POLICY pc_sel ON post_comments; CREATE POLICY pc_sel ON post_comments FOR SELECT TO complex_app
  USING (app_is_member() AND (deleted_at IS NULL OR app_is_admin()));
DROP POLICY pc_ins ON post_comments; CREATE POLICY pc_ins ON post_comments FOR INSERT TO complex_app
  WITH CHECK (app_is_member() AND author_id = app_uid() AND deleted_at IS NULL);
DROP POLICY rep_ins ON reports;      CREATE POLICY rep_ins ON reports FOR INSERT TO complex_app
  WITH CHECK (app_is_member() AND reporter_id = app_uid() AND status = 'dikirim');
DROP POLICY sg_ins ON sigap_alerts;  CREATE POLICY sg_ins ON sigap_alerts FOR INSERT TO complex_app
  WITH CHECK (app_is_member() AND user_id = app_uid() AND status = 'terkirim');

CREATE OR REPLACE VIEW v_community_members WITH (security_barrier = true) AS
  SELECT u.id, u.full_name, b.name AS block, u.role
    FROM users u LEFT JOIN units un ON un.id = u.unit_id LEFT JOIN blocks b ON b.id = un.block_id
   WHERE u.status = 'aktif' AND u.role IN ('admin', 'warga') AND app_is_member();
CREATE OR REPLACE VIEW v_post_stats WITH (security_barrier = true) AS
  SELECT p.id AS post_id,
         (SELECT count(*) FROM post_likes l WHERE l.post_id = p.id)                             AS like_count,
         (SELECT count(*) FROM post_comments c WHERE c.post_id = p.id AND c.deleted_at IS NULL) AS comment_count
    FROM posts p WHERE app_is_member();
