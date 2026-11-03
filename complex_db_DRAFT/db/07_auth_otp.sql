-- =====================================================================
-- COMPLEX — 07: aktivasi akun (login pertama) & reset password lewat OTP email
--
-- Dua alur, satu mesin:
--   (A) LOGIN PERTAMA  : email + password sementara dari admin  -> OTP email  -> set password baru
--   (B) LUPA PASSWORD  : email                                  -> OTP email  -> set password baru
-- OTP benar  => dihasilkan TIKET sekali pakai (10 menit)  => tiket dipakai untuk set password.
--
-- Prinsip keamanan:
--  * OTP 6 digit berentropi rendah, jadi yang disimpan HMAC-SHA256 dengan "pepper" yang HANYA ada di
--    backend (bukan di DB). Kebocoran DB saja tidak cukup untuk menebak kode.
--  * Maks 5 salah per kode; 1 kode aktif per (user, tujuan); cooldown 60 dtk; maks 5/jam & 10/hari.
--  * Role aplikasi TIDAK punya akses langsung ke otp_challenges maupun auth_tokens. Semua lewat fungsi
--    SECURITY DEFINER di bawah, sehingga aplikasi tidak bisa mencetak tiket / menandai akun aktif sendiri.
-- =====================================================================
SET client_min_messages = warning;

-- ---------- status aktivasi menggantikan must_change_password ----------
ALTER TABLE users
  ADD COLUMN activated_at          timestamptz,                                  -- NULL = belum login pertama
  ADD COLUMN activation_expires_at timestamptz DEFAULT (now() + interval '7 days');  -- masa berlaku password sementara
UPDATE users SET activated_at = coalesce(last_login_at, created_at) WHERE must_change_password = false;
ALTER TABLE users DROP COLUMN must_change_password;

-- ---------- helper & guard ----------
CREATE FUNCTION fn_is_app_role() RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT pg_has_role(current_user, 'complex_app', 'MEMBER')
          AND NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) $$;

-- Aplikasi tidak boleh membuat akun yang langsung berstatus aktif (melompati OTP).
CREATE FUNCTION trg_users_activation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF fn_is_app_role() THEN
    IF TG_OP = 'INSERT' THEN
      NEW.activated_at := NULL;
      NEW.activation_expires_at := now() + interval '7 days';
    ELSIF NEW.activated_at IS DISTINCT FROM OLD.activated_at
       OR NEW.activation_expires_at IS DISTINCT FROM OLD.activation_expires_at THEN
      RAISE EXCEPTION 'Status aktivasi hanya dapat diubah lewat fungsi verifikasi OTP.' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER users_activation_guard BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION trg_users_activation_guard();

-- ---------- tabel OTP ----------
CREATE TABLE otp_challenges (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose       auth_token_purpose NOT NULL,            -- 'activation' | 'password_reset'
  code_hash     bytea NOT NULL CHECK (octet_length(code_hash) = 32),   -- HMAC-SHA256(pepper, user|purpose|kode)
  sent_to       text NOT NULL,                          -- snapshot email tujuan
  requested_ip  inet,
  attempts      smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts  smallint NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 10),
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  consumed_at   timestamptz,
  invalidated_at timestamptz,
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '15 minutes')
);
CREATE UNIQUE INDEX otp_one_active ON otp_challenges (user_id, purpose)
  WHERE consumed_at IS NULL AND invalidated_at IS NULL;
CREATE INDEX otp_recent_idx ON otp_challenges (user_id, purpose, created_at DESC);

-- Cabut akses langsung aplikasi ke tabel token/OTP (hanya lewat fungsi di bawah)
REVOKE ALL ON auth_tokens, otp_challenges FROM complex_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- =====================================================================
-- 1. Minta OTP.  Mengembalikan: 'ok' | 'ineligible' | 'cooldown' | 'limit'
--    Backend: buat kode acak 6 digit, hitung HMAC dgn pepper, panggil fungsi ini, KIRIM EMAIL hanya jika 'ok'.
--    Ke pengguna SELALU balas pesan generik (jangan membocorkan 'ineligible').
-- =====================================================================
CREATE FUNCTION fn_otp_issue(p_user uuid, p_purpose auth_token_purpose, p_code_hash bytea, p_ip inet DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u users%ROWTYPE; v_last timestamptz; v_hour int; v_day int;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user FOR UPDATE;          -- serialisasi permintaan per pengguna
  IF NOT FOUND OR u.status <> 'aktif' THEN RETURN 'ineligible'; END IF;
  IF p_purpose = 'activation'     AND (u.activated_at IS NOT NULL OR u.activation_expires_at < now()) THEN RETURN 'ineligible'; END IF;
  IF p_purpose = 'password_reset' AND u.activated_at IS NULL THEN RETURN 'ineligible'; END IF;

  SELECT max(created_at) INTO v_last FROM otp_challenges WHERE user_id = p_user AND purpose = p_purpose;
  IF v_last > now() - interval '60 seconds' THEN RETURN 'cooldown'; END IF;
  SELECT count(*) FILTER (WHERE created_at > now() - interval '1 hour'), count(*)
    INTO v_hour, v_day FROM otp_challenges
   WHERE user_id = p_user AND purpose = p_purpose AND created_at > now() - interval '1 day';
  IF v_hour >= 5 OR v_day >= 10 THEN RETURN 'limit'; END IF;

  UPDATE otp_challenges SET invalidated_at = now()
   WHERE user_id = p_user AND purpose = p_purpose AND consumed_at IS NULL AND invalidated_at IS NULL;
  INSERT INTO otp_challenges (user_id, purpose, code_hash, sent_to, requested_ip, expires_at)
  VALUES (p_user, p_purpose, p_code_hash, u.email, p_ip, now() + interval '10 minutes');
  INSERT INTO audit_logs (actor_id, ip, action, entity, entity_id, details)
  VALUES (p_user, p_ip, 'OTP_ISSUED', 'users', p_user::text, jsonb_build_object('purpose', p_purpose));
  RETURN 'ok';
END $$;

-- =====================================================================
-- 2. Verifikasi OTP.  Mengembalikan: 'ok' | 'invalid' | 'expired' | 'locked'
--    Jika 'ok', TIKET (hash-nya dikirim backend) tersimpan, berlaku 10 menit, sekali pakai.
--    Ke pengguna SEMUA kegagalan dibalas SATU pesan yang sama ("Kode salah atau kedaluwarsa").
-- =====================================================================
CREATE FUNCTION fn_otp_verify(p_user uuid, p_purpose auth_token_purpose, p_code_hash bytea,
                              p_ticket_hash bytea, p_ip inet DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c otp_challenges%ROWTYPE;
BEGIN
  SELECT * INTO c FROM otp_challenges
   WHERE user_id = p_user AND purpose = p_purpose AND consumed_at IS NULL AND invalidated_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RETURN 'invalid'; END IF;
  IF c.expires_at <= now() THEN
    UPDATE otp_challenges SET invalidated_at = now() WHERE id = c.id;
    RETURN 'expired';
  END IF;
  IF c.attempts >= c.max_attempts THEN
    UPDATE otp_challenges SET invalidated_at = now() WHERE id = c.id;
    RETURN 'locked';
  END IF;

  -- HMAC dengan pepper (tidak diketahui penyerang) sehingga perbandingan ini tidak bisa dimanfaatkan sebagai oracle waktu
  IF c.code_hash <> p_code_hash THEN
    UPDATE otp_challenges SET attempts = attempts + 1,
           invalidated_at = CASE WHEN attempts + 1 >= max_attempts THEN now() END
     WHERE id = c.id;
    INSERT INTO audit_logs (actor_id, ip, action, entity, entity_id, details)
    VALUES (p_user, p_ip, CASE WHEN c.attempts + 1 >= c.max_attempts THEN 'OTP_LOCKED' ELSE 'OTP_FAILED' END,
            'users', p_user::text, jsonb_build_object('purpose', p_purpose, 'attempts', c.attempts + 1));
    RETURN CASE WHEN c.attempts + 1 >= c.max_attempts THEN 'locked' ELSE 'invalid' END;
  END IF;

  UPDATE otp_challenges SET consumed_at = now() WHERE id = c.id;
  UPDATE auth_tokens SET used_at = now() WHERE user_id = p_user AND purpose = p_purpose AND used_at IS NULL;
  INSERT INTO auth_tokens (user_id, purpose, token_hash, expires_at, requested_ip)
  VALUES (p_user, p_purpose, p_ticket_hash, now() + interval '10 minutes', p_ip);
  INSERT INTO audit_logs (actor_id, ip, action, entity, entity_id, details)
  VALUES (p_user, p_ip, 'OTP_VERIFIED', 'users', p_user::text, jsonb_build_object('purpose', p_purpose));
  RETURN 'ok';
END $$;

-- =====================================================================
-- 3. Set password dengan tiket.  Mengembalikan user_id, atau NULL jika tiket tidak valid.
--    Efek: password baru, akun menjadi AKTIF, kunci/penghitung gagal direset, SEMUA sesi dicabut.
--    Backend wajib: validasi kebijakan password (min. 12, bukan email/nama), tolak sama dgn password lama,
--    hash Argon2id, lalu kirim hash-nya ke sini.
-- =====================================================================
CREATE FUNCTION fn_set_password(p_ticket_hash bytea, p_new_hash text, p_ip inet DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE t auth_tokens%ROWTYPE;
BEGIN
  SELECT * INTO t FROM auth_tokens
   WHERE token_hash = p_ticket_hash AND used_at IS NULL AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE auth_tokens SET used_at = now() WHERE id = t.id;

  UPDATE users SET password_hash = p_new_hash, activated_at = coalesce(activated_at, now()),
                   failed_login_count = 0, locked_until = NULL
   WHERE id = t.user_id AND status = 'aktif';
  IF NOT FOUND THEN RETURN NULL; END IF;

  UPDATE sessions SET revoked_at = now(), revoked_reason = 'password_changed'
   WHERE user_id = t.user_id AND revoked_at IS NULL;
  INSERT INTO audit_logs (actor_id, ip, action, entity, entity_id, details)
  VALUES (t.user_id, p_ip, 'PASSWORD_SET', 'users', t.user_id::text, jsonb_build_object('via', t.purpose));
  RETURN t.user_id;
END $$;

-- =====================================================================
-- 4. Admin mereset password WARGA (mis. warga tak punya akses email): password sementara baru + aktivasi ulang
-- =====================================================================
CREATE FUNCTION fn_admin_reset_password(p_user uuid, p_temp_hash text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT app_is_admin() THEN
    RAISE EXCEPTION 'Hanya admin yang dapat mereset password warga.' USING ERRCODE = '42501';
  END IF;
  UPDATE users SET password_hash = p_temp_hash, activated_at = NULL,
                   activation_expires_at = now() + interval '7 days', failed_login_count = 0, locked_until = NULL
   WHERE id = p_user AND role = 'warga';
  IF NOT FOUND THEN RAISE EXCEPTION 'Warga tidak ditemukan.'; END IF;
  UPDATE sessions SET revoked_at = now(), revoked_reason = 'admin_reset' WHERE user_id = p_user AND revoked_at IS NULL;
  UPDATE otp_challenges SET invalidated_at = now() WHERE user_id = p_user AND consumed_at IS NULL AND invalidated_at IS NULL;
  UPDATE auth_tokens SET used_at = now() WHERE user_id = p_user AND used_at IS NULL;
  INSERT INTO audit_logs (actor_id, action, entity, entity_id, details)
  VALUES (app_uid(), 'PASSWORD_RESET_BY_ADMIN', 'users', p_user::text, '{}'::jsonb);
END $$;

-- ---------- fungsi lama yang menyentuh tabel yang kini tertutup => jadikan DEFINER ----------
CREATE OR REPLACE FUNCTION anonymize_user(p_user uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT app_is_admin() THEN
    RAISE EXCEPTION 'Hanya admin yang dapat menganonimkan akun.' USING ERRCODE = '42501';
  END IF;
  UPDATE users SET full_name = 'Warga Nonaktif', email = 'removed-' || id || '@anonymized.invalid',
                   phone = NULL, photo_storage_key = NULL, status = 'nonaktif',
                   password_hash = '$2a$06$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvali'
   WHERE id = p_user;
  DELETE FROM sessions WHERE user_id = p_user;
  DELETE FROM auth_tokens WHERE user_id = p_user;
  DELETE FROM otp_challenges WHERE user_id = p_user;
END $$;

CREATE OR REPLACE FUNCTION fn_purge_expired() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  DELETE FROM sessions WHERE expires_at < now() - interval '7 days' OR revoked_at < now() - interval '7 days';
  DELETE FROM auth_tokens WHERE expires_at < now() - interval '1 day';
  DELETE FROM otp_challenges WHERE created_at < now() - interval '2 days';
  DELETE FROM login_attempts WHERE attempted_at < now() - interval '30 days';
$$;

-- ---------- hak eksekusi: hanya yang memang boleh dipanggil aplikasi ----------
REVOKE ALL ON FUNCTION fn_is_app_role(), fn_otp_issue(uuid, auth_token_purpose, bytea, inet),
  fn_otp_verify(uuid, auth_token_purpose, bytea, bytea, inet), fn_set_password(bytea, text, inet),
  fn_admin_reset_password(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_is_app_role(), fn_otp_issue(uuid, auth_token_purpose, bytea, inet),
  fn_otp_verify(uuid, auth_token_purpose, bytea, bytea, inet), fn_set_password(bytea, text, inet),
  fn_admin_reset_password(uuid, text) TO complex_app;
