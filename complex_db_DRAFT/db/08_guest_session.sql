-- =====================================================================
-- COMPLEX — 08: Tamu (guest) TANPA AKUN + Lapor Tamu 1x24 jam + beranda per peran
--
-- Keputusan desain:
--  * Tamu bukan baris di `users`. Tamu = sesi anonim (cookie acak, berlaku 24 jam). Admin tidak mendaftarkan.
--    Hanya dua peran berakun: admin dan warga (`user_role` tidak berubah).
--  * Sesi tamu hanya bisa: membaca berita komplek, memilih blok, membuat/melihat/mengakhiri laporan tamunya
--    sendiri. Semuanya LEWAT FUNGSI (SECURITY DEFINER); role aplikasi tidak punya akses langsung ke
--    `guest_sessions` dan tidak ada policy RLS yang membuka tabel lain tanpa user_id.
--  * Karena endpoint tamu publik (tanpa login), DB menegakkan pembatasan anti-spam per IP dan per sesi.
-- =====================================================================

-- ---------- guard users (diperketat): pembuatan akun HANYA oleh admin ----------
CREATE OR REPLACE FUNCTION trg_users_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE is_app boolean := pg_has_role(current_user, 'complex_app', 'MEMBER')
                          AND NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user);
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF is_app AND NOT app_is_admin() THEN
      RAISE EXCEPTION 'Hanya admin yang dapat mendaftarkan akun.' USING ERRCODE = '42501';
    END IF;
    IF NEW.role = 'admin' THEN
      IF is_app THEN
        RAISE EXCEPTION 'Akun admin hanya dapat dibuat lewat skrip pemilik database, bukan oleh aplikasi.'
          USING ERRCODE = '42501';
      END IF;
      IF NEW.created_by IS NULL AND EXISTS (SELECT 1 FROM users WHERE role = 'admin') THEN
        RAISE EXCEPTION 'Admin berikutnya wajib memiliki created_by (hanya admin pertama yang boleh NULL).';
      END IF;
    END IF;
    IF NEW.created_by IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM users a WHERE a.id = NEW.created_by AND a.role = 'admin' AND a.status = 'aktif') THEN
      RAISE EXCEPTION 'created_by harus merujuk admin yang aktif (akun hanya didaftarkan oleh admin).';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'id, created_by, dan created_at tidak boleh diubah.';
  END IF;
  IF NEW.role IS DISTINCT FROM OLD.role AND is_app THEN
    RAISE EXCEPTION 'Perubahan role hanya dapat dilakukan lewat skrip pemilik database.' USING ERRCODE = '42501';
  END IF;
  IF is_app AND app_uid() IS NOT NULL AND NOT app_is_admin() THEN
    IF OLD.id <> app_uid() THEN
      RAISE EXCEPTION 'Warga hanya dapat mengubah akunnya sendiri.' USING ERRCODE = '42501';
    END IF;
    IF NEW.unit_id IS DISTINCT FROM OLD.unit_id OR NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Rumah (blok/nomor) dan status akun hanya dapat diubah admin.' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF OLD.role = 'admin' AND OLD.status = 'aktif' AND (NEW.role <> 'admin' OR NEW.status <> 'aktif')
     AND NOT EXISTS (SELECT 1 FROM users WHERE role = 'admin' AND status = 'aktif' AND id <> OLD.id) THEN
    RAISE EXCEPTION 'Tidak boleh menonaktifkan/menurunkan admin aktif terakhir.';
  END IF;
  IF NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN
    NEW.password_changed_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION app_is_member() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$ SELECT EXISTS (SELECT 1 FROM users WHERE id = app_uid() AND role IN ('admin','warga') AND status = 'aktif') $$;
GRANT EXECUTE ON FUNCTION app_is_member() TO complex_app;

-- pemuatan sesi akun (admin/warga): satu pintu untuk backend
CREATE FUNCTION fn_session_user(p_token_hash bytea)
RETURNS TABLE (user_id uuid, role user_role, full_name text, unit_id integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.id, u.role, u.full_name, u.unit_id
    FROM sessions s JOIN users u ON u.id = s.user_id
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now()
     AND u.status = 'aktif' AND u.activated_at IS NOT NULL
$$;
GRANT EXECUTE ON FUNCTION fn_session_user(bytea) TO complex_app;

-- =====================================================================
-- SESI TAMU (anonim)
-- =====================================================================
CREATE TABLE guest_sessions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash  bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),   -- SHA-256 dari cookie acak
  ip          inet,
  user_agent  text CHECK (char_length(user_agent) <= 255),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  revoked_at  timestamptz,
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '24 hours')
);
CREATE INDEX guest_sessions_ip_idx ON guest_sessions (ip, created_at DESC);
REVOKE ALL ON guest_sessions FROM complex_app;      -- hanya lewat fungsi di bawah

-- =====================================================================
-- LAPOR TAMU 1x24 JAM
-- =====================================================================
CREATE TYPE visit_status AS ENUM ('aktif', 'selesai', 'dibatalkan');   -- "tidak aktif lagi" diturunkan dari valid_until
CREATE TABLE guest_visits (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id      uuid REFERENCES users(id) ON DELETE RESTRICT,   -- warga/admin pelapor; NULL bila dari sesi tamu
  guest_session_id uuid,                                           -- sesi tamu pelapor (tanpa FK: sesi dibersihkan, laporan tetap)
  visitor_name     text NOT NULL CHECK (char_length(btrim(visitor_name)) BETWEEN 2 AND 100),
  visitor_address  text NOT NULL CHECK (char_length(btrim(visitor_address)) BETWEEN 3 AND 200),
  visitor_phone    text CHECK (visitor_phone ~ '^[0-9]{8,15}$'),
  vehicle_plate    text CHECK (vehicle_plate ~ '^[A-Z0-9 ]{3,12}$'),
  host_block_id    smallint NOT NULL REFERENCES blocks(id) ON DELETE RESTRICT,
  host_house       text NOT NULL CHECK (host_house ~ '^[A-Z0-9/-]{1,10}$'),               -- nomor rumah tujuan (teks)
  host_unit_id     integer REFERENCES units(id) ON DELETE RESTRICT,                      -- terisi bila blok+nomor cocok dengan rumah terdaftar
  host_name        text CHECK (host_name IS NULL OR char_length(btrim(host_name)) BETWEEN 2 AND 100),  -- warga yang dituju (teks bebas)
  purpose          text NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 3 AND 300),
  visit_start      timestamptz NOT NULL DEFAULT now(),
  valid_until      timestamptz NOT NULL,                           -- dihitung trigger: visit_start + 24 jam
  status           visit_status NOT NULL DEFAULT 'aktif',
  ended_at         timestamptz,
  ip               inet,                                           -- jejak anti-penyalahgunaan; dibuang setelah 30 hari
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((reporter_id IS NOT NULL) <> (guest_session_id IS NOT NULL)),
  CHECK (valid_until = visit_start + interval '24 hours'),
  CHECK ((status = 'aktif') = (ended_at IS NULL))
);
CREATE INDEX guest_visits_unit_idx ON guest_visits (host_unit_id, valid_until DESC);
CREATE INDEX guest_visits_session_idx ON guest_visits (guest_session_id, created_at DESC);
CREATE INDEX guest_visits_ip_idx ON guest_visits (ip, created_at DESC);

CREATE FUNCTION trg_guest_visit_before() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r record; n integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.status := 'aktif'; NEW.ended_at := NULL;
    NEW.valid_until := NEW.visit_start + interval '24 hours';
    IF NEW.visit_start < now() - interval '1 hour' OR NEW.visit_start > now() + interval '24 hours' THEN
      RAISE EXCEPTION 'Waktu kunjungan hanya boleh dari 1 jam lalu sampai 24 jam ke depan.';
    END IF;
    IF NEW.reporter_id IS NOT NULL THEN                      -- jalur warga/admin
      SELECT id, role, unit_id INTO r FROM users WHERE id = NEW.reporter_id;
      IF NEW.host_unit_id IS NULL THEN RAISE EXCEPTION 'host_unit_id wajib untuk laporan oleh warga/admin.'; END IF;
      IF r.role = 'warga' AND NEW.host_unit_id IS DISTINCT FROM r.unit_id THEN
        RAISE EXCEPTION 'Warga hanya dapat melaporkan tamu untuk rumahnya sendiri.' USING ERRCODE = '42501';
      END IF;
      SELECT count(*) INTO n FROM guest_visits WHERE reporter_id = r.id AND status = 'aktif' AND valid_until > now();
      IF n >= 10 THEN RAISE EXCEPTION 'Terlalu banyak laporan tamu aktif (maks 10).'; END IF;
    END IF;
    IF NEW.host_unit_id IS NOT NULL THEN
      SELECT block_id, house_number INTO NEW.host_block_id, NEW.host_house FROM units WHERE id = NEW.host_unit_id;
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.reporter_id, NEW.guest_session_id, NEW.visitor_name, NEW.visitor_address, NEW.visitor_phone,
      NEW.vehicle_plate, NEW.host_block_id, NEW.host_house, NEW.host_unit_id, NEW.host_name, NEW.purpose,
      NEW.visit_start, NEW.valid_until, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.reporter_id, OLD.guest_session_id, OLD.visitor_name, OLD.visitor_address, OLD.visitor_phone,
      OLD.vehicle_plate, OLD.host_block_id, OLD.host_house, OLD.host_unit_id, OLD.host_name, OLD.purpose,
      OLD.visit_start, OLD.valid_until, OLD.created_at) THEN
    RAISE EXCEPTION 'Laporan tamu tidak dapat diubah; hanya dapat diselesaikan atau dibatalkan.';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status <> 'aktif' OR NEW.status NOT IN ('selesai','dibatalkan') THEN
      RAISE EXCEPTION 'Transisi status laporan tamu tidak valid.';
    END IF;
    NEW.ended_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guest_visits_before BEFORE INSERT OR UPDATE ON guest_visits FOR EACH ROW EXECUTE FUNCTION trg_guest_visit_before();
CREATE TRIGGER audit_guest_visits AFTER INSERT OR UPDATE OR DELETE ON guest_visits FOR EACH ROW EXECUTE FUNCTION trg_audit_row();

-- notifikasi: admin + penghuni rumah tujuan (bila rumahnya terdaftar)
CREATE FUNCTION trg_guest_visit_notify() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_label text; r record;
BEGIN
  SELECT b.name || ' / ' || NEW.host_house INTO v_label FROM blocks b WHERE b.id = NEW.host_block_id;
  PERFORM fn_notify_admins('Lapor tamu baru', left(NEW.visitor_name || ' → ' || v_label || coalesce(' (untuk ' || NEW.host_name || ')', ''), 500),
                           'tamu.html', 'guest-visit:' || NEW.id);
  IF NEW.host_unit_id IS NOT NULL THEN
    FOR r IN SELECT id FROM users WHERE unit_id = NEW.host_unit_id AND role = 'warga' AND status = 'aktif'
                                    AND id IS DISTINCT FROM NEW.reporter_id LOOP
      PERFORM fn_notify_user(r.id, 'sistem', 'Tamu untuk rumah Anda', left(NEW.visitor_name || ' (berlaku 24 jam)', 500),
                             'tamu.html', 'guest-visit:' || NEW.id || ':' || r.id);
    END LOOP;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guest_visits_notify AFTER INSERT ON guest_visits FOR EACH ROW EXECUTE FUNCTION trg_guest_visit_notify();

-- RLS: untuk admin/warga (tamu tidak punya user_id, jadi tidak pernah lolos policy mana pun)
ALTER TABLE guest_visits ENABLE ROW LEVEL SECURITY;
CREATE POLICY gv_sel ON guest_visits FOR SELECT TO complex_app USING (
  app_is_admin() OR reporter_id = app_uid()
  OR (app_is_member() AND host_unit_id IS NOT NULL AND host_unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid())));
CREATE POLICY gv_ins ON guest_visits FOR INSERT TO complex_app
  WITH CHECK (app_is_member() AND reporter_id = app_uid() AND guest_session_id IS NULL AND status = 'aktif');
CREATE POLICY gv_upd ON guest_visits FOR UPDATE TO complex_app
  USING (app_is_admin() OR (app_is_member() AND reporter_id = app_uid()))
  WITH CHECK (app_is_admin() OR (app_is_member() AND reporter_id = app_uid()));
GRANT SELECT, INSERT ON guest_visits TO complex_app;
GRANT UPDATE (status) ON guest_visits TO complex_app;

CREATE VIEW v_guest_visits WITH (security_invoker = true, security_barrier = true) AS
  SELECT g.id, g.visitor_name, g.visitor_address, g.visitor_phone, g.vehicle_plate, g.purpose,
         b.name AS host_block, g.host_house, g.host_name, g.host_unit_id, g.visit_start, g.valid_until,
         g.status, g.ended_at, g.reporter_id, (g.reporter_id IS NULL) AS from_guest,
         (g.status = 'aktif' AND g.valid_until > now()) AS is_active,
         GREATEST(0, floor(extract(epoch FROM g.valid_until - now())))::int AS seconds_left
    FROM guest_visits g JOIN blocks b ON b.id = g.host_block_id;
GRANT SELECT ON v_guest_visits TO complex_app;

-- =====================================================================
-- FUNGSI JALUR TAMU (publik, tanpa login). Backend mengirim SHA-256 dari cookie `guest_sid` dan IP klien
-- yang sebenarnya (dari proxy tepercaya). Semua balasan berupa kode; pesan ke pengguna disusun backend.
-- =====================================================================
CREATE FUNCTION fn_guest_session_start(p_token_hash bytea, p_ip inet, p_ua text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_token_hash IS NULL OR octet_length(p_token_hash) <> 32 THEN RETURN 'invalid'; END IF;
  IF (SELECT count(*) FROM guest_sessions WHERE ip = p_ip AND created_at > now() - interval '1 hour') >= 20 THEN
    RETURN 'limit';
  END IF;
  INSERT INTO guest_sessions (token_hash, ip, user_agent) VALUES (p_token_hash, p_ip, left(p_ua, 255));
  RETURN 'ok';
EXCEPTION WHEN unique_violation THEN RETURN 'invalid';
END $$;

CREATE FUNCTION fn_guest_home(p_token_hash bytea) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s guest_sessions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM guest_sessions WHERE token_hash = p_token_hash AND revoked_at IS NULL AND expires_at > now();
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'role', 'guest', 'landing', 'beranda_tamu', 'primary_action', 'lapor_tamu', 'expires_at', s.expires_at,
    -- tamu hanya melihat berita komplek (bukan pengumuman pengurus/keamanan internal), tanpa acara
    'announcements', (SELECT coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) FROM (
        SELECT id, title, left(body, 300) AS excerpt, is_pinned, published_at
          FROM announcements WHERE deleted_at IS NULL AND category = 'komplek'
         ORDER BY is_pinned DESC, published_at DESC LIMIT 10) a),
    'blocks', (SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY b.name), '[]'::jsonb) FROM (SELECT id, name FROM blocks) b),
    'my_reports', (SELECT coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) FROM (
        SELECT g.id, g.visitor_name, b.name AS host_block, g.host_house, g.host_name, g.visit_start, g.valid_until, g.status,
               (g.status = 'aktif' AND g.valid_until > now()) AS is_active,
               GREATEST(0, floor(extract(epoch FROM g.valid_until - now())))::int AS seconds_left
          FROM guest_visits g JOIN blocks b ON b.id = g.host_block_id
         WHERE g.guest_session_id = s.id ORDER BY g.created_at DESC LIMIT 5) v));
END $$;

CREATE FUNCTION fn_guest_report_create(
  p_token_hash bytea, p_name text, p_address text, p_block_id smallint, p_house text, p_host_name text,
  p_purpose text, p_phone text, p_plate text, p_visit_start timestamptz, p_ip inet)
RETURNS TABLE (result text, visit_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s guest_sessions%ROWTYPE; v_unit integer; v_house text := upper(btrim(coalesce(p_house, ''))); v_id uuid;
BEGIN
  SELECT * INTO s FROM guest_sessions WHERE token_hash = p_token_hash AND revoked_at IS NULL AND expires_at > now();
  IF NOT FOUND THEN RETURN QUERY SELECT 'no_session', NULL::uuid; RETURN; END IF;
  IF EXISTS (SELECT 1 FROM guest_visits WHERE guest_session_id = s.id AND status = 'aktif' AND valid_until > now()) THEN
    RETURN QUERY SELECT 'active_exists', NULL::uuid; RETURN;
  END IF;
  IF p_ip IS NOT NULL AND ((SELECT count(*) FROM guest_visits WHERE ip = p_ip AND created_at > now() - interval '1 hour') >= 3
     OR (SELECT count(*) FROM guest_visits WHERE ip = p_ip AND created_at > now() - interval '24 hours') >= 5) THEN
    RETURN QUERY SELECT 'limit', NULL::uuid; RETURN;
  END IF;
  SELECT id INTO v_unit FROM units WHERE block_id = p_block_id AND house_number = v_house;
  INSERT INTO guest_visits (guest_session_id, visitor_name, visitor_address, visitor_phone, vehicle_plate,
                            host_block_id, host_house, host_unit_id, host_name, purpose, visit_start, ip)
  VALUES (s.id, btrim(p_name), btrim(p_address), nullif(p_phone, ''), nullif(upper(btrim(coalesce(p_plate, ''))), ''),
          p_block_id, v_house, v_unit, nullif(btrim(coalesce(p_host_name, '')), ''), btrim(p_purpose),
          coalesce(p_visit_start, now()), p_ip)
  RETURNING id INTO v_id;
  RETURN QUERY SELECT 'ok', v_id;
EXCEPTION WHEN check_violation OR foreign_key_violation OR not_null_violation OR raise_exception THEN
  RETURN QUERY SELECT 'invalid', NULL::uuid;
END $$;

CREATE FUNCTION fn_guest_report_end(p_token_hash bytea, p_visit_id uuid, p_status visit_status) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s_id uuid;
BEGIN
  IF p_status NOT IN ('selesai','dibatalkan') THEN RETURN 'invalid'; END IF;
  SELECT id INTO s_id FROM guest_sessions WHERE token_hash = p_token_hash AND revoked_at IS NULL AND expires_at > now();
  IF s_id IS NULL THEN RETURN 'no_session'; END IF;
  UPDATE guest_visits SET status = p_status WHERE id = p_visit_id AND guest_session_id = s_id AND status = 'aktif';
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  RETURN 'ok';
END $$;

REVOKE ALL ON FUNCTION fn_guest_session_start(bytea, inet, text), fn_guest_home(bytea),
  fn_guest_report_create(bytea, text, text, smallint, text, text, text, text, text, timestamptz, inet),
  fn_guest_report_end(bytea, uuid, visit_status) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_guest_session_start(bytea, inet, text), fn_guest_home(bytea),
  fn_guest_report_create(bytea, text, text, smallint, text, text, text, text, text, timestamptz, inet),
  fn_guest_report_end(bytea, uuid, visit_status) TO complex_app;

-- pembersihan: sesi tamu lama dibuang; IP pada laporan tamu dihapus setelah 30 hari (laporan tetap)
CREATE OR REPLACE FUNCTION fn_purge_expired() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  DELETE FROM sessions WHERE expires_at < now() - interval '7 days' OR revoked_at < now() - interval '7 days';
  DELETE FROM auth_tokens WHERE expires_at < now() - interval '1 day';
  DELETE FROM otp_challenges WHERE created_at < now() - interval '2 days';
  DELETE FROM login_attempts WHERE attempted_at < now() - interval '30 days';
  DELETE FROM guest_sessions WHERE expires_at < now() - interval '7 days';
  UPDATE guest_visits SET ip = NULL WHERE ip IS NOT NULL AND created_at < now() - interval '30 days';
$$;

-- =====================================================================
-- BERANDA admin & warga (setelah login). Beranda tamu: fn_guest_home().
-- =====================================================================
CREATE FUNCTION fn_home() RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE u record; v_unit jsonb; v_common jsonb; v_stats jsonb;
BEGIN
  SELECT id, role, full_name, status, activated_at, unit_id, photo_storage_key INTO u FROM users WHERE id = app_uid();
  IF NOT FOUND OR u.status <> 'aktif' OR u.activated_at IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object('block', b.name, 'house_number', un.house_number) INTO v_unit
    FROM units un JOIN blocks b ON b.id = un.block_id WHERE un.id = u.unit_id;
  v_common := jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'full_name', u.full_name, 'role', u.role, 'unit', v_unit,
                               'photo_storage_key', u.photo_storage_key),
    'landing', CASE u.role WHEN 'admin' THEN 'beranda_admin' ELSE 'beranda_warga' END,
    'announcements', (SELECT coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) FROM (
        SELECT id, category, title, left(body, 300) AS excerpt, is_pinned, published_at
          FROM announcements WHERE deleted_at IS NULL
         ORDER BY is_pinned DESC, published_at DESC LIMIT 10) a),
    'events', (SELECT coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) FROM (
        SELECT id, title, location, starts_at, ends_at
          FROM events WHERE deleted_at IS NULL AND coalesce(ends_at, starts_at) >= now()
         ORDER BY starts_at LIMIT 10) e));
  IF u.role = 'admin' THEN
    v_stats := jsonb_build_object(
      'reports_new',          (SELECT count(*) FROM reports WHERE status = 'dikirim'),
      'reports_in_progress',  (SELECT count(*) FROM reports WHERE status = 'diproses'),
      'facility_pending',     (SELECT count(*) FROM facility_requests WHERE status = 'menunggu_konfirmasi'),
      'sigap_open',           (SELECT count(*) FROM sigap_alerts WHERE status IN ('terkirim','diterima','menuju_lokasi')),
      'dues_awaiting_verification', (SELECT count(*) FROM dues_bills WHERE status = 'menunggu_verifikasi'),
      'guests_active',        (SELECT count(*) FROM guest_visits WHERE status = 'aktif' AND valid_until > now()),
      'accounts_not_activated', (SELECT count(*) FROM users WHERE activated_at IS NULL AND status = 'aktif'),
      'unread_notifications', (SELECT count(*) FROM notification_recipients WHERE user_id = u.id AND read_at IS NULL));
  ELSE
    v_stats := jsonb_build_object(
      'unread_notifications', (SELECT count(*) FROM notification_recipients WHERE user_id = u.id AND read_at IS NULL),
      'my_open_reports',      (SELECT count(*) FROM reports WHERE reporter_id = u.id AND status IN ('dikirim','diproses')),
      'my_pending_facility',  (SELECT count(*) FROM facility_requests WHERE requester_id = u.id AND status = 'menunggu_konfirmasi'),
      'my_unpaid_dues',       (SELECT count(*) FROM dues_bills WHERE unit_id = u.unit_id AND status <> 'lunas'),
      'guests_at_my_unit',    (SELECT count(*) FROM guest_visits WHERE host_unit_id = u.unit_id AND status = 'aktif' AND valid_until > now()));
  END IF;
  RETURN v_common || jsonb_build_object('stats', v_stats);
END $$;
GRANT EXECUTE ON FUNCTION fn_home() TO complex_app;
