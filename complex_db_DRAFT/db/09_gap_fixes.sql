-- =====================================================================
-- COMPLEX — 09: Penambal kekurangan hasil audit
--   A. users: password_hash tak lagi terbaca aplikasi; RLS (hanya diri sendiri / admin)
--   B. cleaning_schedule  : jadwal kebersihan (sebelumnya statis di HTML)
--   C. dues_payment_proofs: bukti bayar iuran + verifikasi admin (alur iuran lengkap)
--   D. fn_my_activity     : "Riwayat Aktivitas" di Profil (dari audit_logs, hanya milik sendiri)
-- =====================================================================
SET client_min_messages = warning;

-- ---------- A. users ----------
-- Login pra-autentikasi tidak punya app.user_id, jadi pencarian akun lewat fungsi DEFINER yang sempit.
CREATE FUNCTION fn_login_lookup(p_email text)
RETURNS TABLE (id uuid, password_hash text, status user_status, is_locked boolean,
               activated_at timestamptz, activation_valid boolean, role user_role)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.id, u.password_hash, u.status, (u.locked_until IS NOT NULL AND u.locked_until > now()),
         u.activated_at, (u.activation_expires_at IS NOT NULL AND u.activation_expires_at > now()), u.role
  FROM users u WHERE u.email = p_email
$$;
REVOKE ALL ON FUNCTION fn_login_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_login_lookup(text) TO complex_app;

DO $$
DECLARE cols text;
BEGIN
  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) INTO cols
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='users' AND column_name <> 'password_hash';
  EXECUTE 'REVOKE SELECT ON users FROM complex_app';
  EXECUTE format('GRANT SELECT (%s) ON users TO complex_app', cols);
END $$;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
CREATE POLICY u_sel ON users FOR SELECT TO complex_app USING (id = app_uid() OR app_is_admin());
CREATE POLICY u_ins ON users FOR INSERT TO complex_app WITH CHECK (app_is_admin());
CREATE POLICY u_upd ON users FOR UPDATE TO complex_app USING (id = app_uid() OR app_is_admin())
                                                       WITH CHECK (id = app_uid() OR app_is_admin());
-- Pra-login (fn_login_failed/succeeded, OTP, set password) sudah SECURITY DEFINER; v_community_members
-- dijalankan sebagai pemilik sehingga tetap menampilkan anggota tanpa email/telepon.

-- ---------- B. Jadwal kebersihan ----------
CREATE TABLE cleaning_schedule (
  id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),         -- 1=Senin
  area        text NOT NULL CHECK (char_length(btrim(area)) BETWEEN 2 AND 80),
  block_id    smallint REFERENCES blocks(id) ON DELETE SET NULL,          -- opsional: area = blok tertentu
  start_time  time NOT NULL,
  end_time    time NOT NULL,
  note        text CHECK (char_length(note) <= 200),
  is_active   boolean NOT NULL DEFAULT true,
  updated_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (end_time > start_time),
  UNIQUE (weekday, area)
);
ALTER TABLE cleaning_schedule ENABLE ROW LEVEL SECURITY;
CREATE POLICY cs_sel ON cleaning_schedule FOR SELECT TO complex_app USING (app_uid() IS NOT NULL);
CREATE POLICY cs_ins ON cleaning_schedule FOR INSERT TO complex_app WITH CHECK (app_is_admin());
CREATE POLICY cs_upd ON cleaning_schedule FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
CREATE POLICY cs_del ON cleaning_schedule FOR DELETE TO complex_app USING (app_is_admin());
GRANT SELECT, INSERT, DELETE ON cleaning_schedule TO complex_app;
GRANT UPDATE (weekday, area, block_id, start_time, end_time, note, is_active, updated_by, updated_at) ON cleaning_schedule TO complex_app;
CREATE TRIGGER cleaning_schedule_updated BEFORE UPDATE ON cleaning_schedule FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO cleaning_schedule (weekday, area, block_id, start_time, end_time, note)
SELECT v.d, v.a, b.id, v.s::time, v.e::time, v.n
FROM (VALUES (1,'Jati 1','07:00','09:00',NULL),(2,'Jati 2','07:00','09:00',NULL),(3,'Jati 3','07:00','09:00',NULL),
             (4,'Taman dan fasilitas','07:00','09:00',NULL),(5,'Jalan utama','07:00','09:00',NULL),
             (6,'Kerja bakti warga','06:30','09:00','Contoh jadwal awal; admin dapat mengubah')) AS v(d,a,s,e,n)
LEFT JOIN blocks b ON b.name = v.a;

-- ---------- C. Bukti bayar iuran ----------
CREATE TYPE proof_status AS ENUM ('menunggu', 'diterima', 'ditolak');
CREATE TABLE dues_payment_proofs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bill_id       uuid NOT NULL REFERENCES dues_bills(id) ON DELETE CASCADE,
  uploaded_by   uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  storage_key   text NOT NULL CHECK (storage_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$'),
  paid_amount   numeric(12,0) NOT NULL CHECK (paid_amount > 0),
  paid_on       date NOT NULL CHECK (paid_on <= current_date),
  method        text CHECK (method IN ('transfer','tunai','qris')),
  note          text CHECK (char_length(note) <= 300),
  status        proof_status NOT NULL DEFAULT 'menunggu',
  reviewed_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at   timestamptz,
  reject_reason text CHECK (char_length(reject_reason) <= 300),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'ditolak' OR reject_reason IS NOT NULL),
  CHECK (status = 'menunggu' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);
CREATE INDEX dpp_bill_idx ON dues_payment_proofs (bill_id);
CREATE UNIQUE INDEX dpp_one_pending ON dues_payment_proofs (bill_id) WHERE status = 'menunggu';
ALTER TABLE dues_payment_proofs ENABLE ROW LEVEL SECURITY;
CREATE POLICY dpp_sel ON dues_payment_proofs FOR SELECT TO complex_app USING (
  app_is_admin() OR EXISTS (SELECT 1 FROM dues_bills b WHERE b.id = bill_id
                            AND b.unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid())));
CREATE POLICY dpp_ins ON dues_payment_proofs FOR INSERT TO complex_app WITH CHECK (
  uploaded_by = app_uid() AND status = 'menunggu'
  AND EXISTS (SELECT 1 FROM dues_bills b WHERE b.id = bill_id AND b.status = 'belum_dibayar'
              AND b.unit_id = (SELECT u.unit_id FROM users u WHERE u.id = app_uid())));
CREATE POLICY dpp_upd ON dues_payment_proofs FOR UPDATE TO complex_app USING (app_is_admin()) WITH CHECK (app_is_admin());
GRANT SELECT, INSERT ON dues_payment_proofs TO complex_app;
GRANT UPDATE (status, reviewed_by, reviewed_at, reject_reason) ON dues_payment_proofs TO complex_app;

CREATE FUNCTION trg_dpp_after() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_unit integer; v_nid uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE dues_bills SET status = 'menunggu_verifikasi', updated_at = now()
     WHERE id = NEW.bill_id AND status = 'belum_dibayar';
    INSERT INTO notifications (category, title, body, link)
      VALUES ('sistem', 'Bukti bayar iuran baru', 'Ada bukti pembayaran iuran yang menunggu verifikasi.', 'notifikasi.html')
      RETURNING id INTO v_nid;
    INSERT INTO notification_recipients (notification_id, user_id)
      SELECT v_nid, id FROM users WHERE role = 'admin' AND status = 'aktif';
  ELSE
    IF NEW.status = 'diterima' THEN
      UPDATE dues_bills SET status = 'lunas', paid_at = NEW.paid_on::timestamptz, verified_by = NEW.reviewed_by, updated_at = now()
       WHERE id = NEW.bill_id RETURNING unit_id INTO v_unit;
    ELSIF NEW.status = 'ditolak' THEN
      UPDATE dues_bills SET status = 'belum_dibayar', updated_at = now()
       WHERE id = NEW.bill_id AND status = 'menunggu_verifikasi' RETURNING unit_id INTO v_unit;
    END IF;
    IF v_unit IS NOT NULL THEN
      INSERT INTO notifications (category, title, body, link)
        VALUES ('sistem', CASE NEW.status WHEN 'diterima' THEN 'Iuran dinyatakan lunas' ELSE 'Bukti bayar iuran ditolak' END,
                coalesce(NEW.reject_reason, 'Pembayaran iuran Anda telah diverifikasi admin.'), 'notifikasi.html')
        RETURNING id INTO v_nid;
      INSERT INTO notification_recipients (notification_id, user_id)
        SELECT v_nid, id FROM users WHERE unit_id = v_unit AND status = 'aktif';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION trg_dpp_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'menunggu' THEN RAISE EXCEPTION 'Bukti yang sudah diputuskan tidak dapat diubah.'; END IF;
    IF NEW.status = 'menunggu' THEN RAISE EXCEPTION 'Status hanya dapat diubah menjadi diterima atau ditolak.'; END IF;
    NEW.reviewed_by := app_uid(); NEW.reviewed_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER dpp_guard_bi BEFORE UPDATE ON dues_payment_proofs FOR EACH ROW EXECUTE FUNCTION trg_dpp_guard();
CREATE TRIGGER dpp_after AFTER INSERT OR UPDATE ON dues_payment_proofs FOR EACH ROW EXECUTE FUNCTION trg_dpp_after();

-- ---------- D. Riwayat aktivitas (Profil) ----------
CREATE FUNCTION fn_my_activity(p_limit integer DEFAULT 30)
RETURNS TABLE (occurred_at timestamptz, action text, entity text, entity_id text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT a.occurred_at, a.action, a.entity, a.entity_id FROM audit_logs a
   WHERE a.actor_id = app_uid() AND app_uid() IS NOT NULL
   ORDER BY a.occurred_at DESC LIMIT least(greatest(p_limit, 1), 100)
$$;
REVOKE ALL ON FUNCTION fn_my_activity(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_my_activity(integer) TO complex_app;
