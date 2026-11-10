-- =====================================================================
-- COMPLEX — 10b (OPSIONAL): kasus keamanan + progres + SIGAP untuk security
-- Dipasang SETELAH db/10_security_role.sql:  CASES=1 ./scripts/migrate.sh  (atau psql -f).
-- Tidak termasuk cakupan final saat ini (absen + lihat laporan warga). Disimpan dari rancangan awal.
-- Mengganti fn_home_security() dengan versi yang memuat statistik kasus & SIGAP.
-- =====================================================================
-- ---------------------------------------------------------------------
-- 2) KASUS KEAMANAN + PROGRES
--    Kasus dibuka oleh security/admin (mandiri, dari laporan warga kategori keamanan, atau dari SIGAP).
--    Status kasus hanya berubah lewat pembaruan progres (append-only), bukan UPDATE langsung.
-- ---------------------------------------------------------------------
CREATE TYPE case_status AS ENUM ('baru', 'ditangani', 'menunggu_tindak_lanjut', 'selesai', 'ditutup');
CREATE SEQUENCE security_case_seq;
CREATE TABLE security_cases (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          text UNIQUE,                                                -- KS-2026-0001 (trigger)
  title         text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 150),
  description   text CHECK (char_length(description) <= 2000),
  location_text text CHECK (char_length(location_text) <= 200),
  priority      text NOT NULL DEFAULT 'sedang' CHECK (priority IN ('rendah','sedang','tinggi')),
  status        case_status NOT NULL DEFAULT 'baru',
  report_id     uuid REFERENCES reports(id) ON DELETE SET NULL,             -- sumber: laporan warga (opsional)
  sigap_id      uuid REFERENCES sigap_alerts(id) ON DELETE SET NULL,        -- sumber: SIGAP (opsional)
  created_by    uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  assigned_to   uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz,
  CHECK (report_id IS NULL OR sigap_id IS NULL),
  CHECK ((status = 'ditutup') = (closed_at IS NOT NULL))
);
CREATE INDEX security_cases_status_idx ON security_cases (status, updated_at DESC);

CREATE TABLE security_case_updates (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id      uuid NOT NULL REFERENCES security_cases(id) ON DELETE CASCADE,
  author_id    uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status_after case_status NOT NULL,
  note         text NOT NULL CHECK (char_length(btrim(note)) BETWEEN 1 AND 1000),
  photo_key    text CHECK (photo_key IS NULL OR photo_key ~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX security_case_updates_case_idx ON security_case_updates (case_id, created_at);

CREATE FUNCTION trg_case_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.status := 'baru'; NEW.closed_at := NULL; NEW.updated_at := now();
  NEW.code := 'KS-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('security_case_seq')::text, 4, '0');
  IF NEW.assigned_to IS NULL AND app_is_security() THEN NEW.assigned_to := NEW.created_by; END IF;
  IF NEW.assigned_to IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.assigned_to AND role = 'security' AND status = 'aktif') THEN
    RAISE EXCEPTION 'Kasus hanya dapat ditugaskan ke akun security yang aktif.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER case_before BEFORE INSERT ON security_cases FOR EACH ROW EXECUTE FUNCTION trg_case_before();
CREATE FUNCTION trg_case_assign_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.assigned_to IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.assigned_to AND role = 'security' AND status = 'aktif') THEN
    RAISE EXCEPTION 'Kasus hanya dapat ditugaskan ke akun security yang aktif.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER case_before_assign BEFORE UPDATE OF assigned_to ON security_cases FOR EACH ROW EXECUTE FUNCTION trg_case_assign_check();

CREATE FUNCTION trg_case_notify_new() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM fn_notify_admins('Kasus keamanan baru', left(NEW.code || ': ' || NEW.title, 500), 'keamanan.html', 'case-new:' || NEW.id);
  RETURN NEW;
END $$;
CREATE TRIGGER case_after_ins AFTER INSERT ON security_cases FOR EACH ROW EXECUTE FUNCTION trg_case_notify_new();

-- pembaruan progres: validasi transisi + menggerakkan status kasus (DEFINER karena app tak boleh UPDATE status)
CREATE FUNCTION trg_case_update_after() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE c security_cases%ROWTYPE; ok boolean;
BEGIN
  SELECT * INTO c FROM security_cases WHERE id = NEW.case_id FOR UPDATE;
  ok := (c.status = 'baru'                   AND NEW.status_after IN ('ditangani'))
     OR (c.status = 'ditangani'              AND NEW.status_after IN ('ditangani','menunggu_tindak_lanjut','selesai'))
     OR (c.status = 'menunggu_tindak_lanjut' AND NEW.status_after IN ('menunggu_tindak_lanjut','ditangani','selesai'))
     OR (c.status = 'selesai'                AND NEW.status_after IN ('ditutup','ditangani'));
  IF NOT ok THEN
    RAISE EXCEPTION 'Transisi status kasus % -> % tidak valid.', c.status, NEW.status_after;
  END IF;
  IF NEW.status_after = 'ditutup' AND NOT app_is_admin() THEN
    RAISE EXCEPTION 'Hanya admin yang dapat menutup kasus.' USING ERRCODE = '42501';
  END IF;
  UPDATE security_cases SET status = NEW.status_after, updated_at = now(),
         closed_at = CASE WHEN NEW.status_after = 'ditutup' THEN now() END
   WHERE id = NEW.case_id;
  IF NEW.status_after = 'selesai' THEN
    PERFORM fn_notify_admins('Kasus keamanan selesai', left(c.code || ': ' || c.title, 500), 'keamanan.html', 'case-done:' || NEW.id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER case_update_after AFTER INSERT ON security_case_updates FOR EACH ROW EXECUTE FUNCTION trg_case_update_after();
CREATE TRIGGER audit_security_cases AFTER INSERT OR UPDATE OR DELETE ON security_cases FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_security_case_updates AFTER INSERT OR UPDATE OR DELETE ON security_case_updates FOR EACH ROW EXECUTE FUNCTION trg_audit_row();

ALTER TABLE security_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_case_updates ENABLE ROW LEVEL SECURITY;
CREATE POLICY sc_sel ON security_cases FOR SELECT TO complex_app USING (app_is_staff());
CREATE POLICY sc_ins ON security_cases FOR INSERT TO complex_app WITH CHECK (app_is_staff() AND created_by = app_uid());
CREATE POLICY sc_upd ON security_cases FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());   -- penugasan ulang
CREATE POLICY scu_sel ON security_case_updates FOR SELECT TO complex_app USING (app_is_staff());
CREATE POLICY scu_ins ON security_case_updates FOR INSERT TO complex_app WITH CHECK (app_is_staff() AND author_id = app_uid());
GRANT SELECT, INSERT ON security_cases TO complex_app;
GRANT UPDATE (assigned_to) ON security_cases TO complex_app;
GRANT SELECT, INSERT ON security_case_updates TO complex_app;      -- tanpa UPDATE/DELETE: linimasa append-only
GRANT USAGE ON SEQUENCE security_case_seq TO complex_app;

-- ---------------------------------------------------------------------
-- 3) SIGAP: security ikut menerima & menindaklanjuti
-- ---------------------------------------------------------------------
DROP POLICY sg_sel ON sigap_alerts;
CREATE POLICY sg_sel ON sigap_alerts FOR SELECT TO complex_app USING (user_id = app_uid() OR app_is_staff());
CREATE POLICY sg_upd_security ON sigap_alerts FOR UPDATE TO complex_app USING (app_is_security()) WITH CHECK (app_is_security());

CREATE FUNCTION trg_sigap_notify_security() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM users WHERE role = 'security' AND status = 'aktif' AND activated_at IS NOT NULL LOOP
    PERFORM fn_notify_user(r.id, 'sistem', 'SIGAP: peringatan darurat', coalesce(NEW.contact_name, 'Warga') || ' menekan tombol SIGAP.',
                           'sigap.html', 'sigap-sec:' || NEW.id || ':' || r.id);
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER sigap_after_ins_security AFTER INSERT ON sigap_alerts FOR EACH ROW EXECUTE FUNCTION trg_sigap_notify_security();

-- ---------------------------------------------------------------------
-- 4) BERANDA SECURITY (setelah login). Backend memanggil ini bila role = security.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_home_security() RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE u record; v_att record;
BEGIN
  SELECT id, role, full_name, status, activated_at, photo_storage_key INTO u FROM users WHERE id = app_uid() AND role = 'security';
  IF NOT FOUND OR u.status <> 'aktif' OR u.activated_at IS NULL THEN RETURN NULL; END IF;
  SELECT id, check_in_at INTO v_att FROM security_attendance WHERE user_id = u.id AND check_out_at IS NULL;
  RETURN jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'full_name', u.full_name, 'role', u.role, 'photo_storage_key', u.photo_storage_key),
    'landing', 'beranda_security',
    'attendance', jsonb_build_object('on_duty', v_att.id IS NOT NULL, 'since', v_att.check_in_at),
    'announcements', (SELECT coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) FROM (
        SELECT id, category, title, left(body, 300) AS excerpt, is_pinned, published_at
          FROM announcements WHERE deleted_at IS NULL ORDER BY is_pinned DESC, published_at DESC LIMIT 10) a),
    'stats', jsonb_build_object(
      'cases_open',       (SELECT count(*) FROM security_cases WHERE status NOT IN ('selesai','ditutup')),
      'my_cases_open',    (SELECT count(*) FROM security_cases WHERE assigned_to = u.id AND status NOT IN ('selesai','ditutup')),
      'sigap_open',       (SELECT count(*) FROM sigap_alerts WHERE status IN ('terkirim','diterima','menuju_lokasi')),
      'reports_keamanan_new', (SELECT count(*) FROM reports WHERE category = 'keamanan' AND status = 'dikirim'),
      'unread_notifications', (SELECT count(*) FROM notification_recipients WHERE user_id = u.id AND read_at IS NULL)));
END $$;
GRANT EXECUTE ON FUNCTION fn_home_security() TO complex_app;

