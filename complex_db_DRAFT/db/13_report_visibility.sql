-- =====================================================================
-- COMPLEX — 13: visibilitas laporan & log (keputusan tim)
--   * Daftar laporan: HANYA admin dan satpam. Warga hanya melihat laporan MILIKNYA sendiri (dan membuat laporan).
--   * Log (report_status_history, audit_logs): HANYA admin. Warga melihat progres laporannya lewat status laporan sendiri
--     dan fn_my_report_progress() (urutan status + waktu, tanpa pelaku dan tanpa catatan internal satpam/admin).
-- Sebelumnya (04_rls) semua pengguna berakun dapat membaca seluruh laporan, dan pelapor membaca riwayat laporannya.
-- =====================================================================
SET client_min_messages = warning;

DROP POLICY rep_sel ON reports;
CREATE POLICY rep_sel ON reports FOR SELECT TO complex_app
  USING (app_is_staff() OR reporter_id = app_uid());

DROP POLICY rh_sel ON report_status_history;
CREATE POLICY rh_sel ON report_status_history FOR SELECT TO complex_app
  USING (app_is_admin());

CREATE FUNCTION fn_my_report_progress(p_report uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('from_status', h.from_status, 'to_status', h.to_status, 'at', h.changed_at)
                            ORDER BY h.changed_at, h.id), '[]'::jsonb)
    FROM report_status_history h
    JOIN reports r ON r.id = h.report_id
   WHERE h.report_id = p_report AND r.reporter_id = app_uid()
$$;
REVOKE ALL ON FUNCTION fn_my_report_progress(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_my_report_progress(uuid) TO complex_app;
