-- =====================================================================
-- COMPLEX — 08: role ketiga "guest" (tamu) + Lapor Tamu 1x24 jam + data beranda per role
--
-- Aturan yang dipertahankan:
--  * Tidak ada pendaftaran mandiri: akun guest juga HANYA dibuat admin (users.created_by = admin).
--  * guest hanya boleh: membaca beranda (berita komplek) dan membuat/melihat laporan tamunya sendiri lewat
--    tombol utama "Lapor Tamu" (nama, alamat asal, rumah/warga tujuan, keperluan). Guest tidak punya rumah. Semua tabel lain tertutup untuk guest oleh RLS.
--  * Akun guest berbatas waktu (users.access_expires_at, maks 7 hari dari sekarang saat diset);
--    setelah lewat, RLS menganggapnya tidak ada walau sesi lamanya belum dibuang.
--  * "Lapor tamu 1x24 jam": satu laporan berlaku tepat 24 jam sejak waktu kunjungan (dihitung DB, bukan klien).
-- =====================================================================
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'guest';

-- ---------- users: masa berlaku akses tamu ----------
ALTER TABLE users ADD COLUMN access_expires_at timestamptz;
ALTER TABLE users ADD CONSTRAINT guest_wajib_punya_batas_akses
  CHECK ((role = 'guest') = (access_expires_at IS NOT NULL));
ALTER TABLE users DROP CONSTRAINT warga_wajib_punya_rumah;
ALTER TABLE users ADD CONSTRAINT warga_wajib_punya_rumah CHECK (role IN ('admin','guest') OR unit_id IS NOT NULL);
ALTER TABLE users ADD CONSTRAINT guest_tanpa_rumah CHECK (role <> 'guest' OR unit_id IS NULL);   -- tujuan dipilih per laporan
ALTER TABLE users ADD CONSTRAINT akses_setelah_dibuat
  CHECK (access_expires_at IS NULL OR access_expires_at > created_at);
GRANT UPDATE (access_expires_at) ON users TO complex_app;

-- ---------- fungsi peran (membaca DB, bukan cookie/klien) ----------
CREATE FUNCTION app_is_member() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$ SELECT EXISTS (SELECT 1 FROM users WHERE id = app_uid() AND role IN ('admin','warga') AND status = 'aktif') $$;

CREATE FUNCTION app_is_guest() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$ SELECT EXISTS (SELECT 1 FROM users WHERE id = app_uid() AND role = 'guest' AND status = 'aktif'
                    AND access_expires_at > now()) $$;

CREATE FUNCTION app_can_read_home() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$ SELECT app_is_member() OR app_is_guest() $$;
GRANT EXECUTE ON FUNCTION app_is_member(), app_is_guest(), app_can_read_home() TO complex_app;

-- ---------- guard users (diganti): pembuatan akun HANYA oleh admin ----------
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
    IF NEW.role = 'guest' AND NEW.access_expires_at > now() + interval '7 days' THEN
      RAISE EXCEPTION 'Akses tamu maksimal 7 hari dari sekarang.';
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
      RAISE EXCEPTION 'Pengguna non-admin hanya dapat mengubah akunnya sendiri.' USING ERRCODE = '42501';
    END IF;
    IF NEW.unit_id IS DISTINCT FROM OLD.unit_id OR NEW.status IS DISTINCT FROM OLD.status
       OR NEW.access_expires_at IS DISTINCT FROM OLD.access_expires_at THEN
      RAISE EXCEPTION 'Rumah, status akun, dan masa akses hanya dapat diubah admin.' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF NEW.access_expires_at IS DISTINCT FROM OLD.access_expires_at AND NEW.role = 'guest'
     AND NEW.access_expires_at > now() + interval '7 days' THEN
    RAISE EXCEPTION 'Akses tamu maksimal 7 hari dari sekarang.';
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

-- sesi tamu tidak boleh melewati masa akses
CREATE FUNCTION trg_session_guest_clamp() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_role user_role; v_until timestamptz;
BEGIN
  SELECT role, access_expires_at INTO v_role, v_until FROM users WHERE id = NEW.user_id;
  IF v_role = 'guest' THEN
    IF v_until <= now() THEN RAISE EXCEPTION 'Akses tamu telah berakhir.' USING ERRCODE = '42501'; END IF;
    NEW.expires_at := LEAST(NEW.expires_at, v_until);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER sessions_guest_clamp BEFORE INSERT ON sessions FOR EACH ROW EXECUTE FUNCTION trg_session_guest_clamp();

-- pemuatan sesi: satu pintu untuk backend (cek sesi, status, aktivasi, masa akses tamu)
CREATE FUNCTION fn_session_user(p_token_hash bytea)
RETURNS TABLE (user_id uuid, role user_role, full_name text, unit_id integer, access_expires_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT u.id, u.role, u.full_name, u.unit_id, u.access_expires_at
    FROM sessions s JOIN users u ON u.id = s.user_id
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now()
     AND u.status = 'aktif' AND u.activated_at IS NOT NULL
     AND (u.role <> 'guest' OR u.access_expires_at > now())
$$;
GRANT EXECUTE ON FUNCTION fn_session_user(bytea) TO complex_app;

-- pengumuman => notifikasi hanya ke admin & warga (tamu cukup melihat beranda)
CREATE OR REPLACE FUNCTION trg_announcement_fanout() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO notifications (category, title, body, link, source_key, announcement_id)
  VALUES ('pengumuman', NEW.title, left(NEW.body, 200), 'beranda.html', 'announcement:' || NEW.id, NEW.id)
  RETURNING id INTO v_id;
  INSERT INTO notification_recipients (notification_id, user_id)
  SELECT v_id, id FROM users WHERE status = 'aktif' AND role IN ('admin','warga');
  RETURN NEW;
END $$;

-- =====================================================================
-- RLS: "semua pengguna login" kini berarti admin/warga. guest hanya dibuka untuk beranda.
-- =====================================================================
-- beranda: pengumuman, acara, referensi blok/rumah (tujuan kunjungan) -> admin, warga, tamu aktif
DROP POLICY ref_sel ON blocks;       CREATE POLICY ref_sel ON blocks FOR SELECT TO complex_app USING (app_can_read_home());
DROP POLICY ref_sel ON units;        CREATE POLICY ref_sel ON units  FOR SELECT TO complex_app USING (app_can_read_home());
DROP POLICY ann_sel ON announcements;
CREATE POLICY ann_sel ON announcements FOR SELECT TO complex_app USING (app_can_read_home() AND (deleted_at IS NULL OR app_is_admin()));
DROP POLICY evt_sel ON events;
CREATE POLICY evt_sel ON events FOR SELECT TO complex_app USING (app_can_read_home() AND (deleted_at IS NULL OR app_is_admin()));

-- selebihnya: hanya admin/warga
DROP POLICY grd_sel ON security_guards;     CREATE POLICY grd_sel ON security_guards FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY shf_sel ON security_shift_config; CREATE POLICY shf_sel ON security_shift_config FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY rep_sel ON reports;             CREATE POLICY rep_sel ON reports FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY rep_ins ON reports;             CREATE POLICY rep_ins ON reports FOR INSERT TO complex_app WITH CHECK (app_is_member() AND reporter_id = app_uid() AND status = 'dikirim');
DROP POLICY fr_ins ON facility_requests;    CREATE POLICY fr_ins ON facility_requests FOR INSERT TO complex_app WITH CHECK (app_is_member() AND requester_id = app_uid() AND status = 'menunggu_konfirmasi');
DROP POLICY sg_ins ON sigap_alerts;         CREATE POLICY sg_ins ON sigap_alerts FOR INSERT TO complex_app WITH CHECK (app_is_member() AND user_id = app_uid() AND status = 'terkirim');
DROP POLICY db_sel ON dues_bills;
CREATE POLICY db_sel ON dues_bills FOR SELECT TO complex_app
  USING (app_is_admin() OR (app_is_member() AND unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid())));
DROP POLICY po_sel ON posts;    CREATE POLICY po_sel ON posts FOR SELECT TO complex_app USING (app_is_member() AND (deleted_at IS NULL OR app_is_admin()));
DROP POLICY po_ins ON posts;    CREATE POLICY po_ins ON posts FOR INSERT TO complex_app WITH CHECK (app_is_member() AND author_id = app_uid() AND deleted_at IS NULL);
DROP POLICY pm_sel ON post_media; CREATE POLICY pm_sel ON post_media FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY pm_ins ON post_media; CREATE POLICY pm_ins ON post_media FOR INSERT TO complex_app
  WITH CHECK (app_is_member() AND EXISTS (SELECT 1 FROM posts p WHERE p.id = post_id AND p.author_id = app_uid()));
DROP POLICY pl_sel ON post_likes; CREATE POLICY pl_sel ON post_likes FOR SELECT TO complex_app USING (app_is_member());
DROP POLICY pl_ins ON post_likes; CREATE POLICY pl_ins ON post_likes FOR INSERT TO complex_app WITH CHECK (app_is_member() AND user_id = app_uid());
DROP POLICY pc_sel ON post_comments; CREATE POLICY pc_sel ON post_comments FOR SELECT TO complex_app USING (app_is_member() AND (deleted_at IS NULL OR app_is_admin()));
DROP POLICY pc_ins ON post_comments; CREATE POLICY pc_ins ON post_comments FOR INSERT TO complex_app WITH CHECK (app_is_member() AND author_id = app_uid() AND deleted_at IS NULL);

-- view komunitas hanya untuk admin/warga, dan tamu tidak ikut terdaftar sebagai anggota
CREATE OR REPLACE VIEW v_community_members WITH (security_barrier = true) AS
  SELECT u.id, u.full_name, b.name AS block, u.role
    FROM users u LEFT JOIN units un ON un.id = u.unit_id LEFT JOIN blocks b ON b.id = un.block_id
   WHERE u.status = 'aktif' AND u.role IN ('admin','warga') AND app_is_member();
CREATE OR REPLACE VIEW v_post_stats WITH (security_barrier = true) AS
  SELECT p.id AS post_id,
         (SELECT count(*) FROM post_likes l WHERE l.post_id = p.id)                             AS like_count,
         (SELECT count(*) FROM post_comments c WHERE c.post_id = p.id AND c.deleted_at IS NULL) AS comment_count
    FROM posts p WHERE app_is_member();

-- =====================================================================
-- LAPOR TAMU 1x24 JAM
-- =====================================================================
CREATE TYPE visit_status AS ENUM ('aktif', 'selesai', 'dibatalkan');   -- "kedaluwarsa" diturunkan dari valid_until
CREATE TABLE guest_visits (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id    uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,   -- tamu sendiri / warga tuan rumah / admin
  guest_user_id  uuid REFERENCES users(id) ON DELETE RESTRICT,            -- diisi bila pelapor adalah akun guest
  visitor_name   text NOT NULL CHECK (char_length(btrim(visitor_name)) BETWEEN 2 AND 100),
  visitor_address text NOT NULL CHECK (char_length(btrim(visitor_address)) BETWEEN 3 AND 200),   -- alamat asal tamu
  visitor_phone  text CHECK (visitor_phone ~ '^[0-9]{8,15}$'),
  vehicle_plate  text CHECK (vehicle_plate ~ '^[A-Z0-9 ]{3,12}$'),
  host_unit_id   integer NOT NULL REFERENCES units(id) ON DELETE RESTRICT,   -- rumah tujuan (dipilih blok + nomor)
  host_name      text CHECK (host_name IS NULL OR char_length(btrim(host_name)) BETWEEN 2 AND 100),  -- nama warga yang dituju (teks bebas; daftar warga tidak dibuka ke tamu)
  purpose        text NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 3 AND 300),
  visit_start    timestamptz NOT NULL DEFAULT now(),
  valid_until    timestamptz NOT NULL,                                    -- dihitung trigger: visit_start + 24 jam
  status         visit_status NOT NULL DEFAULT 'aktif',
  ended_at       timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_until = visit_start + interval '24 hours'),
  CHECK ((status = 'aktif') = (ended_at IS NULL))
);
CREATE INDEX guest_visits_unit_idx ON guest_visits (host_unit_id, valid_until DESC);
CREATE INDEX guest_visits_reporter_idx ON guest_visits (reporter_id, created_at DESC);

CREATE FUNCTION trg_guest_visit_before() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r users%ROWTYPE; n integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO r FROM users WHERE id = NEW.reporter_id;
    NEW.status := 'aktif'; NEW.ended_at := NULL;
    NEW.valid_until := NEW.visit_start + interval '24 hours';
    IF NEW.visit_start < now() - interval '1 hour' OR NEW.visit_start > now() + interval '24 hours' THEN
      RAISE EXCEPTION 'Waktu kunjungan hanya boleh dari 1 jam lalu sampai 24 jam ke depan.';
    END IF;
    IF r.role = 'warga' AND NEW.host_unit_id IS DISTINCT FROM r.unit_id THEN
      RAISE EXCEPTION 'Warga hanya dapat melaporkan tamu untuk rumahnya sendiri.' USING ERRCODE = '42501';
    END IF;
    IF r.role = 'guest' THEN
      IF NEW.guest_user_id IS NOT NULL AND NEW.guest_user_id <> r.id THEN
        RAISE EXCEPTION 'guest_user_id harus akun pelapor sendiri.' USING ERRCODE = '42501';
      END IF;
      NEW.guest_user_id := r.id;
      SELECT count(*) INTO n FROM guest_visits WHERE reporter_id = r.id AND status = 'aktif' AND valid_until > now();
      IF n >= 1 THEN RAISE EXCEPTION 'Masih ada laporan tamu yang aktif; tunggu berakhir atau selesaikan dulu.'; END IF;
    ELSE
      NEW.guest_user_id := NULL;
      SELECT count(*) INTO n FROM guest_visits WHERE reporter_id = r.id AND status = 'aktif' AND valid_until > now();
      IF n >= 10 THEN RAISE EXCEPTION 'Terlalu banyak laporan tamu aktif (maks 10).'; END IF;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: hanya aktif -> selesai/dibatalkan; kolom lain tidak boleh berubah
  IF (NEW.id, NEW.reporter_id, NEW.guest_user_id, NEW.visitor_name, NEW.visitor_address, NEW.visitor_phone, NEW.vehicle_plate,
      NEW.host_unit_id, NEW.host_name, NEW.purpose, NEW.visit_start, NEW.valid_until, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.reporter_id, OLD.guest_user_id, OLD.visitor_name, OLD.visitor_address, OLD.visitor_phone, OLD.vehicle_plate,
      OLD.host_unit_id, OLD.host_name, OLD.purpose, OLD.visit_start, OLD.valid_until, OLD.created_at) THEN
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

-- notifikasi: admin + penghuni rumah tujuan
CREATE FUNCTION trg_guest_visit_notify() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_label text; r record;
BEGIN
  SELECT b.name || ' / ' || un.house_number INTO v_label FROM units un JOIN blocks b ON b.id = un.block_id WHERE un.id = NEW.host_unit_id;
  PERFORM fn_notify_admins('Lapor tamu baru', left(NEW.visitor_name || ' → ' || v_label || coalesce(' (untuk ' || NEW.host_name || ')', ''), 500), 'tamu.html', 'guest-visit:' || NEW.id);
  FOR r IN SELECT id FROM users WHERE unit_id = NEW.host_unit_id AND role = 'warga' AND status = 'aktif' AND id <> NEW.reporter_id LOOP
    PERFORM fn_notify_user(r.id, 'sistem', 'Tamu untuk rumah Anda', left(NEW.visitor_name || ' (berlaku 24 jam)', 500), 'tamu.html',
                           'guest-visit:' || NEW.id || ':' || r.id);
  END LOOP;
  RETURN NEW;
END $$;
CREATE TRIGGER guest_visits_notify AFTER INSERT ON guest_visits FOR EACH ROW EXECUTE FUNCTION trg_guest_visit_notify();

ALTER TABLE guest_visits ENABLE ROW LEVEL SECURITY;
CREATE POLICY gv_sel ON guest_visits FOR SELECT TO complex_app USING (
  app_is_admin() OR reporter_id = app_uid()
  OR (app_is_member() AND host_unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid())));
CREATE POLICY gv_ins ON guest_visits FOR INSERT TO complex_app
  WITH CHECK (reporter_id = app_uid() AND status = 'aktif' AND (app_is_member() OR app_is_guest()));
CREATE POLICY gv_upd ON guest_visits FOR UPDATE TO complex_app
  USING (app_is_admin() OR (reporter_id = app_uid() AND (app_is_member() OR app_is_guest())))
  WITH CHECK (app_is_admin() OR (reporter_id = app_uid() AND (app_is_member() OR app_is_guest())));
GRANT SELECT, INSERT ON guest_visits TO complex_app;
GRANT UPDATE (status) ON guest_visits TO complex_app;

CREATE VIEW v_guest_visits WITH (security_invoker = true, security_barrier = true) AS
  SELECT g.id, g.visitor_name, g.visitor_address, g.host_name, g.visitor_phone, g.vehicle_plate, g.purpose, g.visit_start, g.valid_until,
         g.status, g.ended_at, b.name AS host_block, un.house_number AS host_house, g.reporter_id,
         (g.status = 'aktif' AND g.valid_until > now()) AS is_active,
         GREATEST(0, floor(extract(epoch FROM g.valid_until - now())))::int AS seconds_left
    FROM guest_visits g JOIN units un ON un.id = g.host_unit_id JOIN blocks b ON b.id = un.block_id;
GRANT SELECT ON v_guest_visits TO complex_app;

-- =====================================================================
-- BERANDA PER ROLE: satu panggilan setelah login. Mengikuti RLS (SECURITY INVOKER).
-- 'landing' = kunci logis halaman beranda; pemetaan ke halaman frontend menyusul.
-- =====================================================================
CREATE FUNCTION fn_home() RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE u users%ROWTYPE; v_unit jsonb; v_common jsonb; v_stats jsonb;
BEGIN
  SELECT * INTO u FROM users WHERE id = app_uid();
  IF NOT FOUND OR u.status <> 'aktif' OR u.activated_at IS NULL
     OR (u.role = 'guest' AND u.access_expires_at <= now()) THEN
    RETURN NULL;
  END IF;
  SELECT jsonb_build_object('block', b.name, 'house_number', un.house_number) INTO v_unit
    FROM units un JOIN blocks b ON b.id = un.block_id WHERE un.id = u.unit_id;

  v_common := jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'full_name', u.full_name, 'role', u.role, 'unit', v_unit,
                               'photo_storage_key', u.photo_storage_key, 'access_expires_at', u.access_expires_at),
    'landing', CASE u.role WHEN 'admin' THEN 'beranda_admin' WHEN 'warga' THEN 'beranda_warga' ELSE 'beranda_tamu' END,
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
  ELSIF u.role = 'warga' THEN
    v_stats := jsonb_build_object(
      'unread_notifications', (SELECT count(*) FROM notification_recipients WHERE user_id = u.id AND read_at IS NULL),
      'my_open_reports',      (SELECT count(*) FROM reports WHERE reporter_id = u.id AND status IN ('dikirim','diproses')),
      'my_pending_facility',  (SELECT count(*) FROM facility_requests WHERE requester_id = u.id AND status = 'menunggu_konfirmasi'),
      'my_unpaid_dues',       (SELECT count(*) FROM dues_bills WHERE unit_id = u.unit_id AND status <> 'lunas'),
      'guests_at_my_unit',    (SELECT count(*) FROM guest_visits WHERE host_unit_id = u.unit_id AND status = 'aktif' AND valid_until > now()));
  ELSE
    v_stats := jsonb_build_object(
      'primary_action', 'lapor_tamu',
      'my_active_visit', (SELECT to_jsonb(v) FROM (
          SELECT id, visitor_name, visit_start, valid_until FROM guest_visits
           WHERE reporter_id = u.id AND status = 'aktif' AND valid_until > now()
           ORDER BY valid_until DESC LIMIT 1) v));
  END IF;
  RETURN v_common || jsonb_build_object('stats', v_stats);
END $$;
GRANT EXECUTE ON FUNCTION fn_home() TO complex_app;
