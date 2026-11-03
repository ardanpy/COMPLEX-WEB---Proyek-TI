-- =====================================================================
-- COMPLEX — 03: logika keamanan, audit, notifikasi otomatis, hak akses
-- =====================================================================
SET client_min_messages = warning;

-- ---------- konteks request (di-set backend per transaksi: SET LOCAL / set_config(...,true)) ----------
--   app.user_id  = UUID pengguna dari SESI SERVER (bukan dari cookie/body)
--   app.ip       = IP klien (opsional, utk audit)
CREATE FUNCTION app_uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

-- Admin ditentukan dari TABEL users, bukan dari variabel sesi yang bisa dipalsukan.
CREATE FUNCTION app_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$ SELECT EXISTS (SELECT 1 FROM users WHERE id = app_uid() AND role = 'admin' AND status = 'aktif') $$;

-- =====================================================================
-- 1. Guard tabel users
-- =====================================================================
CREATE FUNCTION trg_users_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE is_app boolean := pg_has_role(current_user, 'complex_app', 'MEMBER')
                          AND NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user);  -- superuser = anggota semua role
BEGIN
  IF TG_OP = 'INSERT' THEN
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

  -- UPDATE
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'id, created_by, dan created_at tidak boleh diubah.';
  END IF;
  IF NEW.role IS DISTINCT FROM OLD.role AND is_app THEN
    RAISE EXCEPTION 'Perubahan role hanya dapat dilakukan lewat skrip pemilik database.' USING ERRCODE = '42501';
  END IF;
  -- bukan-admin (konteks sesi aplikasi) hanya boleh mengubah akunnya sendiri, dan tidak boleh
  -- mengubah rumah/status. Penjaga ini menahan BUG otorisasi (IDOR); konteks tanpa sesi (login) tidak terpengaruh.
  IF is_app AND app_uid() IS NOT NULL AND NOT app_is_admin() THEN
    IF OLD.id <> app_uid() THEN
      RAISE EXCEPTION 'Warga hanya dapat mengubah akunnya sendiri.' USING ERRCODE = '42501';
    END IF;
    IF NEW.unit_id IS DISTINCT FROM OLD.unit_id OR NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'Rumah (blok/nomor) dan status akun hanya dapat diubah admin.' USING ERRCODE = '42501';
    END IF;
  END IF;
  -- jangan sampai tidak ada admin aktif tersisa
  IF OLD.role = 'admin' AND OLD.status = 'aktif' AND (NEW.role <> 'admin' OR NEW.status <> 'aktif')
     AND NOT EXISTS (SELECT 1 FROM users WHERE role = 'admin' AND status = 'aktif' AND id <> OLD.id) THEN
    RAISE EXCEPTION 'Tidak boleh menonaktifkan/menurunkan admin aktif terakhir.';
  END IF;
  -- ganti password => catat waktu & cabut sesi lain dilakukan backend; waktu dicatat di sini
  IF NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN
    NEW.password_changed_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER users_guard BEFORE INSERT OR UPDATE ON users FOR EACH ROW EXECUTE FUNCTION trg_users_guard();

-- Anonimisasi (hak penghapusan data): data pribadi dibuang, riwayat tetap utuh.
CREATE FUNCTION anonymize_user(p_user uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users SET full_name = 'Warga Nonaktif',
                   email = 'removed-' || id || '@anonymized.invalid',
                   phone = NULL, status = 'nonaktif',
                   password_hash = '$2a$06$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvali'
   WHERE id = p_user;
  DELETE FROM sessions WHERE user_id = p_user;
  DELETE FROM auth_tokens WHERE user_id = p_user;
END $$;

-- =====================================================================
-- 2. Login: hitung gagal, kunci akun sementara, catat percobaan
-- =====================================================================
CREATE FUNCTION fn_login_failed(p_user uuid, p_email text, p_ip inet DEFAULT NULL, p_ua text DEFAULT NULL)
RETURNS timestamptz LANGUAGE plpgsql AS $$
DECLARE v_locked timestamptz;
BEGIN
  INSERT INTO login_attempts (email, user_id, ip, success, user_agent)
  VALUES (left(coalesce(p_email, ''), 254), p_user, p_ip, false, left(p_ua, 255));
  IF p_user IS NULL THEN RETURN NULL; END IF;
  UPDATE users SET failed_login_count = failed_login_count + 1,
         locked_until = CASE WHEN failed_login_count + 1 >= 5 THEN now() + interval '15 minutes' ELSE locked_until END
   WHERE id = p_user RETURNING locked_until INTO v_locked;
  IF v_locked IS NOT NULL AND v_locked > now() THEN
    INSERT INTO audit_logs (actor_id, ip, action, entity, entity_id, details)
    VALUES (p_user, p_ip, 'ACCOUNT_LOCKED', 'users', p_user::text, jsonb_build_object('until', v_locked));
  END IF;
  RETURN v_locked;
END $$;

CREATE FUNCTION fn_login_succeeded(p_user uuid, p_email text, p_ip inet DEFAULT NULL, p_ua text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO login_attempts (email, user_id, ip, success, user_agent)
  VALUES (left(coalesce(p_email, ''), 254), p_user, p_ip, true, left(p_ua, 255));
  UPDATE users SET failed_login_count = 0, locked_until = NULL, last_login_at = now() WHERE id = p_user;
END $$;

CREATE FUNCTION fn_purge_expired() RETURNS void LANGUAGE sql AS $$
  DELETE FROM sessions WHERE expires_at < now() - interval '7 days' OR revoked_at < now() - interval '7 days';
  DELETE FROM auth_tokens WHERE expires_at < now() - interval '1 day';
  DELETE FROM login_attempts WHERE attempted_at < now() - interval '30 days';
$$;

-- =====================================================================
-- 3. Audit log append-only
-- =====================================================================
CREATE FUNCTION trg_audit_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'audit_logs bersifat append-only (% ditolak).', TG_OP USING ERRCODE = '42501'; END $$;
CREATE TRIGGER audit_no_mutation BEFORE UPDATE OR DELETE ON audit_logs FOR EACH ROW EXECUTE FUNCTION trg_audit_immutable();
CREATE TRIGGER audit_no_truncate BEFORE TRUNCATE ON audit_logs FOR EACH STATEMENT EXECUTE FUNCTION trg_audit_immutable();

CREATE FUNCTION trg_audit_row() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE o jsonb; n jsonb; d jsonb; j jsonb; v_ip inet;
  v_actor uuid;
BEGIN
  BEGIN v_ip := nullif(current_setting('app.ip', true), '')::inet; EXCEPTION WHEN others THEN v_ip := NULL; END;
  BEGIN v_actor := app_uid(); EXCEPTION WHEN others THEN v_actor := NULL; END;

  IF TG_OP = 'INSERT' THEN
    j := to_jsonb(NEW) - 'password_hash'; d := jsonb_build_object('new', j);
  ELSIF TG_OP = 'DELETE' THEN
    j := to_jsonb(OLD) - 'password_hash'; d := jsonb_build_object('old', j);
  ELSE
    o := to_jsonb(OLD); n := to_jsonb(NEW); j := n - 'password_hash';
    SELECT jsonb_object_agg(k, jsonb_build_object('old', o -> k, 'new', n -> k)) INTO d
      FROM jsonb_object_keys(n) AS k
     WHERE (o -> k) IS DISTINCT FROM (n -> k)
       AND k NOT IN ('updated_at', 'password_hash', 'failed_login_count', 'last_login_at', 'password_changed_at');
    IF (o -> 'password_hash') IS DISTINCT FROM (n -> 'password_hash') THEN
      d := coalesce(d, '{}'::jsonb) || jsonb_build_object('password_hash_changed', true);
    END IF;
    IF d IS NULL THEN RETURN NEW; END IF;
  END IF;

  INSERT INTO audit_logs (actor_id, actor_role, ip, action, entity, entity_id, details)
  VALUES (v_actor, nullif(current_setting('app.user_role', true), ''), v_ip, TG_OP, TG_TABLE_NAME,
          coalesce(j ->> 'id', j ->> 'slot'), d);
  RETURN coalesce(NEW, OLD);
END $$;

CREATE TRIGGER audit_users          AFTER INSERT OR UPDATE OR DELETE ON users                 FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_reports        AFTER INSERT OR UPDATE OR DELETE ON reports               FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_facility       AFTER INSERT OR UPDATE OR DELETE ON facility_requests     FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_announcements  AFTER INSERT OR UPDATE OR DELETE ON announcements        FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_events         AFTER INSERT OR UPDATE OR DELETE ON events                FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_guards         AFTER INSERT OR UPDATE OR DELETE ON security_guards       FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_shift          AFTER INSERT OR UPDATE OR DELETE ON security_shift_config FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_sigap          AFTER INSERT OR UPDATE OR DELETE ON sigap_alerts          FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_dues           AFTER INSERT OR UPDATE OR DELETE ON dues_bills            FOR EACH ROW EXECUTE FUNCTION trg_audit_row();
CREATE TRIGGER audit_units          AFTER INSERT OR UPDATE OR DELETE ON units                 FOR EACH ROW EXECUTE FUNCTION trg_audit_row();

-- =====================================================================
-- 4. Notifikasi otomatis (menggantikan localStorage di navigation.js)
-- =====================================================================
CREATE FUNCTION fn_notify_user(p_user uuid, p_cat notif_category, p_title text, p_body text,
                               p_link text, p_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO notifications (category, title, body, link, source_key)
  VALUES (p_cat, p_title, left(coalesce(p_body, ''), 500), p_link, p_key)
  ON CONFLICT (source_key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    INSERT INTO notification_recipients (notification_id, user_id) VALUES (v_id, p_user);
  END IF;
END $$;

CREATE FUNCTION fn_notify_admins(p_title text, p_body text, p_link text, p_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO notifications (category, title, body, link, source_key)
  VALUES ('sistem', p_title, left(coalesce(p_body, ''), 500), p_link, p_key)
  ON CONFLICT (source_key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    INSERT INTO notification_recipients (notification_id, user_id)
    SELECT v_id, id FROM users WHERE role = 'admin' AND status = 'aktif';
  END IF;
END $$;

-- Pengumuman => notifikasi ke semua pengguna aktif
CREATE FUNCTION trg_announcement_fanout() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO notifications (category, title, body, link, source_key, announcement_id)
  VALUES ('pengumuman', NEW.title, left(NEW.body, 200), 'beranda.html', 'announcement:' || NEW.id, NEW.id)
  RETURNING id INTO v_id;
  INSERT INTO notification_recipients (notification_id, user_id)
  SELECT v_id, id FROM users WHERE status = 'aktif';
  RETURN NEW;
END $$;
CREATE TRIGGER announcements_fanout AFTER INSERT ON announcements FOR EACH ROW EXECUTE FUNCTION trg_announcement_fanout();

-- Laporan: riwayat status + notifikasi
CREATE FUNCTION trg_report_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.resolved_at := CASE WHEN NEW.status IN ('selesai', 'ditolak') THEN now() ELSE NULL END;
    IF NEW.handled_by IS NULL THEN NEW.handled_by := app_uid(); END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER reports_before_upd BEFORE UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION trg_report_before();

CREATE FUNCTION trg_report_after() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_link text; v_actor uuid;
BEGIN
  v_link := CASE NEW.category WHEN 'kebersihan' THEN 'kebersihan.html' WHEN 'keamanan' THEN 'keamanan.html' ELSE 'lapor.html' END;
  SELECT id INTO v_actor FROM users WHERE id = app_uid();
  IF TG_OP = 'INSERT' THEN
    INSERT INTO report_status_history (report_id, from_status, to_status, changed_by)
    VALUES (NEW.id, NULL, NEW.status, NEW.reporter_id);
    PERFORM fn_notify_user(NEW.reporter_id, 'sistem', 'Laporan berhasil dibuat',
            NEW.title || ' (' || NEW.category || ') berhasil dikirim untuk ditindaklanjuti.', v_link, 'report-new:' || NEW.id);
    PERFORM fn_notify_admins('Laporan baru: ' || NEW.title, 'Kategori ' || NEW.category || ' di ' || NEW.location_text, v_link, 'report-admin:' || NEW.id);
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO report_status_history (report_id, from_status, to_status, changed_by, note)
    VALUES (NEW.id, OLD.status, NEW.status, v_actor, NEW.admin_note);
    PERFORM fn_notify_user(NEW.reporter_id, 'sistem', 'Status laporan diperbarui',
            NEW.title || ' sekarang berstatus ' || NEW.status || '.', v_link,
            'report-status:' || NEW.id || ':' || NEW.status);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER reports_after_ins AFTER INSERT ON reports FOR EACH ROW EXECUTE FUNCTION trg_report_after();
CREATE TRIGGER reports_after_upd AFTER UPDATE OF status ON reports FOR EACH ROW EXECUTE FUNCTION trg_report_after();

-- Fasilitas
CREATE FUNCTION trg_facility_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('disetujui', 'ditolak') THEN
    NEW.decided_at := now();
    NEW.decided_by := app_uid();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER facility_before_upd BEFORE UPDATE ON facility_requests FOR EACH ROW EXECUTE FUNCTION trg_facility_before();

CREATE FUNCTION trg_facility_after() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM fn_notify_user(NEW.requester_id, 'sistem', 'Pengajuan ' || NEW.facility || ' dicatat',
            NEW.code || ' untuk ' || NEW.use_date || ' pukul ' || to_char(NEW.start_time, 'HH24:MI') || '. Menunggu konfirmasi pengurus.',
            'fasilitas.html', 'facility-new:' || NEW.id);
    PERFORM fn_notify_admins('Pengajuan ' || NEW.facility || ' baru', NEW.applicant_name || ' — ' || NEW.code, 'fasilitas.html', 'facility-admin:' || NEW.id);
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM fn_notify_user(NEW.requester_id, 'sistem', 'Pengajuan ' || NEW.facility || ' ' || replace(NEW.status::text, '_', ' '),
            NEW.code || ' kini berstatus ' || replace(NEW.status::text, '_', ' ') || coalesce('. ' || NEW.decision_note, ''),
            'fasilitas.html', 'facility-status:' || NEW.id || ':' || NEW.status);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER facility_after_ins AFTER INSERT ON facility_requests FOR EACH ROW EXECUTE FUNCTION trg_facility_after();
CREATE TRIGGER facility_after_upd AFTER UPDATE OF status ON facility_requests FOR EACH ROW EXECUTE FUNCTION trg_facility_after();

-- SIGAP
CREATE FUNCTION trg_sigap_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status = 'diterima'       THEN NEW.acknowledged_at := now(); NEW.acknowledged_by := app_uid();
    ELSIF NEW.status = 'menuju_lokasi' THEN NEW.dispatched_at := now();
    ELSIF NEW.status IN ('selesai', 'dibatalkan') THEN NEW.resolved_at := now(); NEW.resolved_by := app_uid();
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER sigap_before_upd BEFORE UPDATE ON sigap_alerts FOR EACH ROW EXECUTE FUNCTION trg_sigap_before();

CREATE FUNCTION trg_sigap_after() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM fn_notify_admins('SIGAP: peringatan darurat', coalesce(NEW.contact_name, 'Warga') || ' menekan tombol SIGAP.', 'sigap.html', 'sigap-admin:' || NEW.id);
  ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.user_id IS NOT NULL THEN
    PERFORM fn_notify_user(NEW.user_id, 'sistem', 'Status SIGAP diperbarui', 'Peringatan Anda: ' || replace(NEW.status::text, '_', ' ') || '.', 'sigap.html',
            'sigap-status:' || NEW.id || ':' || NEW.status);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER sigap_after_ins AFTER INSERT ON sigap_alerts FOR EACH ROW EXECUTE FUNCTION trg_sigap_after();
CREATE TRIGGER sigap_after_upd AFTER UPDATE OF status ON sigap_alerts FOR EACH ROW EXECUTE FUNCTION trg_sigap_after();

-- Soft-delete postingan/komentar: catat siapa
CREATE FUNCTION trg_softdelete_by() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL AND NEW.deleted_by IS NULL THEN NEW.deleted_by := app_uid(); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER posts_softdel    BEFORE UPDATE ON posts         FOR EACH ROW EXECUTE FUNCTION trg_softdelete_by();
CREATE TRIGGER comments_softdel BEFORE UPDATE ON post_comments FOR EACH ROW EXECUTE FUNCTION trg_softdelete_by();

-- =====================================================================
-- 5. View aman (tidak membocorkan email/telepon/hash)
-- =====================================================================
CREATE VIEW v_community_members WITH (security_barrier = true) AS
  SELECT u.id, u.full_name, b.name AS block, u.role
    FROM users u LEFT JOIN units un ON un.id = u.unit_id LEFT JOIN blocks b ON b.id = un.block_id
   WHERE u.status = 'aktif';

CREATE VIEW v_post_stats WITH (security_barrier = true) AS
  SELECT p.id AS post_id,
         (SELECT count(*) FROM post_likes l WHERE l.post_id = p.id)                                AS like_count,
         (SELECT count(*) FROM post_comments c WHERE c.post_id = p.id AND c.deleted_at IS NULL)    AS comment_count
    FROM posts p;

-- =====================================================================
-- 6. HAK AKSES MINIMAL untuk role aplikasi
-- =====================================================================
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO complex_app;

GRANT SELECT ON blocks, units TO complex_app;
GRANT INSERT, UPDATE ON units TO complex_app;
GRANT INSERT ON blocks TO complex_app;

-- users: kolom role/created_by/created_at/id TIDAK dapat diubah oleh aplikasi
GRANT SELECT, INSERT ON users TO complex_app;
GRANT UPDATE (full_name, email, phone, status, unit_id, password_hash, must_change_password,
              password_changed_at, failed_login_count, locked_until, last_login_at) ON users TO complex_app;

GRANT SELECT, INSERT, DELETE ON sessions TO complex_app;
GRANT UPDATE (last_seen_at, expires_at, revoked_at, revoked_reason, csrf_hash) ON sessions TO complex_app;
GRANT SELECT, INSERT ON auth_tokens TO complex_app;
GRANT UPDATE (used_at) ON auth_tokens TO complex_app;
GRANT SELECT, INSERT, DELETE ON login_attempts TO complex_app;

GRANT SELECT, INSERT ON announcements, events TO complex_app;
GRANT UPDATE (category, title, body, is_pinned, deleted_at) ON announcements TO complex_app;
GRANT UPDATE (title, description, location, starts_at, ends_at, deleted_at) ON events TO complex_app;
GRANT SELECT ON notifications TO complex_app;
GRANT SELECT ON notification_recipients TO complex_app;
GRANT UPDATE (read_at) ON notification_recipients TO complex_app;

GRANT SELECT, INSERT ON reports TO complex_app;
GRANT UPDATE (status, handled_by, admin_note) ON reports TO complex_app;
GRANT SELECT ON report_status_history TO complex_app;

GRANT SELECT, INSERT ON facility_requests TO complex_app;
GRANT UPDATE (status, decision_note) ON facility_requests TO complex_app;

GRANT SELECT, INSERT ON security_guards TO complex_app;
GRANT UPDATE (name, phone, updated_by, updated_at) ON security_guards TO complex_app;
GRANT SELECT ON security_shift_config TO complex_app;
GRANT UPDATE (shift_start, shift_hours, configured, updated_by, updated_at) ON security_shift_config TO complex_app;

GRANT SELECT, INSERT ON sigap_alerts TO complex_app;
GRANT UPDATE (status, resolution_note) ON sigap_alerts TO complex_app;

GRANT SELECT, INSERT ON dues_bills TO complex_app;
GRANT UPDATE (amount_idr, due_date, status, paid_at, verified_by, note) ON dues_bills TO complex_app;

GRANT SELECT, INSERT ON posts TO complex_app;
GRANT UPDATE (body, deleted_at, deleted_by) ON posts TO complex_app;
GRANT SELECT, INSERT, DELETE ON post_media, post_likes TO complex_app;
GRANT SELECT, INSERT ON post_comments TO complex_app;
GRANT UPDATE (deleted_at, deleted_by) ON post_comments TO complex_app;

GRANT SELECT, INSERT ON audit_logs TO complex_app;          -- tanpa UPDATE/DELETE
GRANT SELECT ON v_community_members, v_post_stats TO complex_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO complex_app;

GRANT EXECUTE ON FUNCTION app_uid(), app_is_admin(), anonymize_user(uuid), fn_purge_expired(),
  fn_login_failed(uuid, text, inet, text), fn_login_succeeded(uuid, text, inet, text) TO complex_app;
