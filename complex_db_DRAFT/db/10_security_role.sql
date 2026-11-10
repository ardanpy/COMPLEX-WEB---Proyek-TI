-- =====================================================================
-- COMPLEX — 10: role SECURITY (satpam)  [FINAL]
-- Cakupan (disepakati tim):
--   1. Absen masuk & pulang DENGAN FOTO; waktu selalu dari jam server (timestamp tak bisa dipalsukan klien).
--   2. Melihat laporan masalah warga (hanya baca; tidak bisa mengubah status laporan).
--   3. Beranda khusus security (fn_home_security).
--   Tambahan kecil: membaca Lapor Tamu untuk pengecekan di gerbang; slot petugas dapat ditautkan ke akun security.
-- Fitur kasus keamanan + progres + SIGAP untuk security dipindah ke db/optional/10b_security_cases.sql
-- (tidak dimuat secara bawaan; pasang dengan CASES=1 ./scripts/migrate.sh bila tim memutuskan memakainya).
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
-- 2) LAPORAN WARGA UNTUK SECURITY (hanya baca)
--    Kebijakan rep_sel (04_rls) sudah mengizinkan pengguna berakun membaca tabel reports; ubah status hanya admin
--    (rep_upd) dan membuat laporan hanya atas nama sendiri (rep_ins), sehingga security tidak dapat mengubah laporan.
--    View ini sengaja dijalankan sebagai PEMILIK (bukan security_invoker), karena RLS users (09) hanya mengizinkan
--    membaca baris sendiri; tanpa ini nama pelapor tak terbaca. Pengaman: WHERE app_is_staff(), hanya nama pelapor
--    (tanpa telepon/email) dan tanpa admin_note internal.
-- ---------------------------------------------------------------------
CREATE VIEW v_reports_for_security WITH (security_barrier = true) AS
  SELECT r.id, r.category, r.title, r.description, r.location_text, r.block_id, r.incident_date,
         r.status, r.created_at, r.updated_at,
         u.full_name AS reporter_name
    FROM reports r JOIN users u ON u.id = r.reporter_id
   WHERE app_is_staff();
GRANT SELECT ON v_reports_for_security TO complex_app;

-- ---------------------------------------------------------------------
-- 3) BERANDA SECURITY (setelah login). Backend memanggil ini bila role = security.
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
      'reports_open',         (SELECT count(*) FROM reports WHERE status IN ('dikirim','diproses')),
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

