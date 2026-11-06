-- =====================================================================
-- PLAN (RANCANGAN, BELUM FINAL) — 09: peran SECURITY (satpam)
-- Tidak dimuat oleh scripts/migrate.sh. Muat manual setelah 01–08 dengan tests/plan/run_plan.sh
-- (atau: psql -d <db> -v ON_ERROR_STOP=1 -f db/plan/PLAN_10_security_role.sql).
-- Setelah tim menyetujui, berkas ini dipindah/diganti nama menjadi db/09_security_role.sql.
--
-- Cakupan utama (sesuai arahan tim):
--   1. masuk (login akun) untuk membuat laporan/kasus keamanan
--   2. absen security dengan FOTO (masuk & pulang)
--   3. progres kasus (linimasa pembaruan status + catatan + foto)
-- Pertanyaan terbuka ada di docs/plan/PLAN_SECURITY.md.
-- =====================================================================
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'security';

-- security = staf, tidak terikat rumah; tetap hanya dibuat admin (created_by wajib)
ALTER TABLE users DROP CONSTRAINT warga_wajib_punya_rumah;
ALTER TABLE users ADD CONSTRAINT warga_wajib_punya_rumah CHECK (role IN ('admin','security') OR unit_id IS NOT NULL);

CREATE FUNCTION app_is_security() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$ SELECT EXISTS (SELECT 1 FROM users WHERE id = app_uid() AND role = 'security' AND status = 'aktif' AND activated_at IS NOT NULL) $$;
CREATE FUNCTION app_is_staff() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$ SELECT app_is_admin() OR app_is_security() $$;
GRANT EXECUTE ON FUNCTION app_is_security(), app_is_staff() TO complex_app;

-- admin juga boleh mereset password akun security
CREATE OR REPLACE FUNCTION fn_admin_reset_password(p_user uuid, p_temp_hash text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT app_is_admin() THEN
    RAISE EXCEPTION 'Hanya admin yang dapat mereset password warga/security.' USING ERRCODE = '42501';
  END IF;
  UPDATE users SET password_hash = p_temp_hash, activated_at = NULL,
                   activation_expires_at = now() + interval '7 days', failed_login_count = 0, locked_until = NULL
   WHERE id = p_user AND role IN ('warga','security');
  IF NOT FOUND THEN RAISE EXCEPTION 'Akun tidak ditemukan.'; END IF;
  UPDATE sessions SET revoked_at = now(), revoked_reason = 'admin_reset' WHERE user_id = p_user AND revoked_at IS NULL;
  UPDATE otp_challenges SET invalidated_at = now() WHERE user_id = p_user AND consumed_at IS NULL AND invalidated_at IS NULL;
  UPDATE auth_tokens SET used_at = now() WHERE user_id = p_user AND used_at IS NULL;
  INSERT INTO audit_logs (actor_id, action, entity, entity_id, details)
  VALUES (app_uid(), 'PASSWORD_RESET_BY_ADMIN', 'users', p_user::text, '{}'::jsonb);
END $$;

-- ---------------------------------------------------------------------
-- 1) ABSEN DENGAN FOTO
--    Waktu masuk/pulang SELALU dari jam server (klien tidak bisa mengirim waktu).
--    Foto disimpan sebagai storage_key buatan server (uuid.ext), sama seperti foto profil.
-- ---------------------------------------------------------------------
CREATE TABLE security_attendance (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  check_in_at        timestamptz NOT NULL DEFAULT now(),
  check_in_photo_key text NOT NULL CHECK (check_in_photo_key ~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'),
  check_out_at       timestamptz,
  check_out_photo_key text CHECK (check_out_photo_key IS NULL OR check_out_photo_key ~
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'),
  note               text CHECK (char_length(note) <= 300),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK ((check_out_at IS NULL) = (check_out_photo_key IS NULL)),
  CHECK (check_out_at IS NULL OR check_out_at > check_in_at)
);
CREATE UNIQUE INDEX security_attendance_one_open ON security_attendance (user_id) WHERE check_out_at IS NULL;
CREATE INDEX security_attendance_user_idx ON security_attendance (user_id, check_in_at DESC);

CREATE FUNCTION trg_attendance_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.check_in_at := now(); NEW.check_out_at := NULL; NEW.check_out_photo_key := NULL;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.user_id, NEW.check_in_at, NEW.check_in_photo_key, NEW.created_at)
     IS DISTINCT FROM (OLD.id, OLD.user_id, OLD.check_in_at, OLD.check_in_photo_key, OLD.created_at) THEN
    RAISE EXCEPTION 'Data absen masuk tidak dapat diubah.';
  END IF;
  IF OLD.check_out_at IS NOT NULL THEN RAISE EXCEPTION 'Absen pulang sudah tercatat dan tidak dapat diubah.'; END IF;
  IF NEW.check_out_photo_key IS NOT NULL THEN NEW.check_out_at := now(); END IF;   -- jam pulang dari server
  RETURN NEW;
END $$;
CREATE TRIGGER attendance_before BEFORE INSERT OR UPDATE ON security_attendance FOR EACH ROW EXECUTE FUNCTION trg_attendance_before();
CREATE TRIGGER audit_security_attendance AFTER INSERT OR UPDATE OR DELETE ON security_attendance FOR EACH ROW EXECUTE FUNCTION trg_audit_row();

ALTER TABLE security_attendance ENABLE ROW LEVEL SECURITY;
CREATE POLICY att_sel ON security_attendance FOR SELECT TO complex_app USING (app_is_admin() OR (app_is_security() AND user_id = app_uid()));
CREATE POLICY att_ins ON security_attendance FOR INSERT TO complex_app WITH CHECK (app_is_security() AND user_id = app_uid());
CREATE POLICY att_upd ON security_attendance FOR UPDATE TO complex_app
  USING (app_is_security() AND user_id = app_uid()) WITH CHECK (app_is_security() AND user_id = app_uid());
GRANT SELECT, INSERT ON security_attendance TO complex_app;
GRANT UPDATE (check_out_photo_key, note) ON security_attendance TO complex_app;

CREATE VIEW v_security_attendance WITH (security_invoker = true, security_barrier = true) AS
  SELECT a.id, a.user_id, u.full_name, a.check_in_at, a.check_in_photo_key, a.check_out_at, a.check_out_photo_key, a.note,
         (a.check_out_at IS NULL) AS on_duty,
         floor(extract(epoch FROM coalesce(a.check_out_at, now()) - a.check_in_at) / 60)::int AS duration_minutes
    FROM security_attendance a JOIN users u ON u.id = a.user_id;
GRANT SELECT ON v_security_attendance TO complex_app;

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
CREATE FUNCTION fn_home_security() RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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

-- =====================================================================
-- PLAN: integrasi tambahan security
--  1) security melihat laporan tamu (Lapor Tamu) untuk pengecekan di gerbang (hanya baca)
--  2) slot petugas (security_guards) dapat ditautkan ke akun security
-- =====================================================================
DROP POLICY gv_sel ON guest_visits;
CREATE POLICY gv_sel ON guest_visits FOR SELECT TO complex_app USING (
  app_is_admin() OR app_is_security() OR reporter_id = app_uid()
  OR (app_is_member() AND host_unit_id IS NOT NULL AND host_unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid())));

ALTER TABLE security_guards ADD COLUMN user_id uuid UNIQUE REFERENCES users(id) ON DELETE SET NULL;
GRANT UPDATE (user_id) ON security_guards TO complex_app;
CREATE FUNCTION trg_guard_user_check() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id AND role = 'security') THEN
    RAISE EXCEPTION 'Slot petugas hanya dapat ditautkan ke akun ber-role security.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER security_guards_user_check BEFORE INSERT OR UPDATE OF user_id ON security_guards
  FOR EACH ROW EXECUTE FUNCTION trg_guard_user_check();
