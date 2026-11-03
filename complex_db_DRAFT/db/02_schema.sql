-- =====================================================================
-- COMPLEX — 02: skema inti (PostgreSQL 16+)
-- Konvensi: identifier Inggris snake_case, nilai enum Indonesia (sama dgn label UI).
-- PK publik = UUID (anti-enumerasi / IDOR); tabel referensi kecil = integer.
-- =====================================================================
SET client_min_messages = warning;

-- ---------- ENUM ----------
CREATE TYPE user_role           AS ENUM ('admin', 'warga');
CREATE TYPE user_status         AS ENUM ('aktif', 'nonaktif', 'ditangguhkan');
CREATE TYPE report_category     AS ENUM ('kebersihan', 'fasilitas', 'keamanan', 'lainnya');
CREATE TYPE report_status       AS ENUM ('dikirim', 'diproses', 'selesai', 'ditolak');
CREATE TYPE report_recipient    AS ENUM ('penanggung_jawab_kebersihan', 'pengurus_rt');
CREATE TYPE facility_type       AS ENUM ('ambulans', 'lapangan', 'mushola');
CREATE TYPE request_status      AS ENUM ('menunggu_konfirmasi', 'disetujui', 'ditolak', 'dibatalkan', 'selesai');
CREATE TYPE sigap_status        AS ENUM ('terkirim', 'diterima', 'menuju_lokasi', 'selesai', 'dibatalkan');
CREATE TYPE notif_category      AS ENUM ('pengumuman', 'komunitas', 'sistem');
CREATE TYPE announcement_category AS ENUM ('komplek', 'pengurus', 'keamanan', 'kebersihan');
CREATE TYPE bill_status         AS ENUM ('belum_dibayar', 'menunggu_verifikasi', 'lunas');
CREATE TYPE media_type          AS ENUM ('image', 'video');
CREATE TYPE auth_token_purpose  AS ENUM ('activation', 'password_reset');

-- ---------- util ----------
CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- =====================================================================
-- A. WILAYAH
-- =====================================================================
CREATE TABLE blocks (
  id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name      text NOT NULL UNIQUE CHECK (char_length(name) BETWEEN 1 AND 30)   -- 'Jati 1' .. 'Jati 7'
);

CREATE TABLE units (                       -- satu rumah
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  block_id     smallint NOT NULL REFERENCES blocks(id) ON DELETE RESTRICT,
  house_number text NOT NULL CHECK (house_number ~ '^[0-9A-Za-z/-]{1,10}$'),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (block_id, house_number)
);

-- =====================================================================
-- B. AKUN & AUTENTIKASI  (tidak ada pendaftaran mandiri: lihat trigger di 03)
-- =====================================================================
CREATE TABLE users (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                text NOT NULL
                         CHECK (email = lower(email) AND char_length(email) <= 254
                                AND email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  full_name            text NOT NULL CHECK (char_length(btrim(full_name)) BETWEEN 2 AND 100),
  phone                text CHECK (phone ~ '^[0-9]{8,15}$'),                  -- digit saja, sudah dinormalisasi (62...)
  role                 user_role   NOT NULL DEFAULT 'warga',
  status               user_status NOT NULL DEFAULT 'aktif',
  unit_id              integer REFERENCES units(id) ON DELETE RESTRICT,
  -- hanya hash (argon2id / bcrypt). CHECK menolak password plaintext yang tak sengaja tersimpan.
  password_hash        text NOT NULL CHECK (password_hash ~ '^\$(argon2id|2[aby])\$'),
  must_change_password boolean NOT NULL DEFAULT true,                          -- true utk password sementara dari admin
  password_changed_at  timestamptz,
  failed_login_count   integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
  locked_until         timestamptz,
  last_login_at        timestamptz,
  created_by           uuid REFERENCES users(id) ON DELETE RESTRICT,           -- admin yang mendaftarkan
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT warga_wajib_punya_rumah CHECK (role = 'admin' OR unit_id IS NOT NULL),
  CONSTRAINT warga_wajib_didaftarkan_admin CHECK (role = 'admin' OR created_by IS NOT NULL)
);
CREATE UNIQUE INDEX users_email_uq ON users (email);
CREATE INDEX users_unit_idx ON users (unit_id);
CREATE INDEX users_role_status_idx ON users (role, status);
CREATE TRIGGER users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Sesi server-side. Cookie berisi token acak opaque; DB hanya menyimpan SHA-256-nya.
CREATE TABLE sessions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash      bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  csrf_hash       bytea CHECK (csrf_hash IS NULL OR octet_length(csrf_hash) = 32),
  remember        boolean NOT NULL DEFAULT false,                               -- "Remember for 30 days"
  ip              inet,
  user_agent      text CHECK (char_length(user_agent) <= 255),
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,                                         -- batas absolut
  revoked_at      timestamptz,
  revoked_reason  text CHECK (char_length(revoked_reason) <= 100),
  CHECK (expires_at > created_at)
);
CREATE INDEX sessions_user_idx ON sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_expiry_idx ON sessions (expires_at);

-- Token sekali pakai (reset password / aktivasi). Hanya hash yang disimpan.
CREATE TABLE auth_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose     auth_token_purpose NOT NULL,
  token_hash  bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  requested_ip inet,
  CHECK (expires_at > created_at)
);
CREATE INDEX auth_tokens_user_idx ON auth_tokens (user_id, purpose) WHERE used_at IS NULL;

-- Jejak percobaan login untuk rate-limit & deteksi brute force.
CREATE TABLE login_attempts (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email         text NOT NULL CHECK (char_length(email) <= 254),   -- apa adanya (boleh email tak terdaftar)
  user_id       uuid REFERENCES users(id) ON DELETE SET NULL,
  ip            inet,
  success       boolean NOT NULL,
  user_agent    text CHECK (char_length(user_agent) <= 255),
  attempted_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_attempts_email_idx ON login_attempts (lower(email), attempted_at DESC);
CREATE INDEX login_attempts_ip_idx    ON login_attempts (ip, attempted_at DESC);

-- =====================================================================
-- C. INFORMASI: PENGUMUMAN, ACARA, NOTIFIKASI
-- =====================================================================
CREATE TABLE announcements (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category     announcement_category NOT NULL DEFAULT 'komplek',
  title        text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 150),
  body         text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 5000),
  is_pinned    boolean NOT NULL DEFAULT false,
  published_at timestamptz NOT NULL DEFAULT now(),
  created_by   uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz
);
CREATE INDEX announcements_pub_idx ON announcements (published_at DESC) WHERE deleted_at IS NULL;
CREATE TRIGGER announcements_updated BEFORE UPDATE ON announcements FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE events (                      -- "Acara Mendatang" di Beranda
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title        text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 150),
  description  text CHECK (char_length(description) <= 2000),
  location     text CHECK (char_length(location) <= 150),
  starts_at    timestamptz NOT NULL,
  ends_at      timestamptz,
  created_by   uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,
  CHECK (ends_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX events_start_idx ON events (starts_at) WHERE deleted_at IS NULL;
CREATE TRIGGER events_updated BEFORE UPDATE ON events FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE notifications (               -- isi notifikasi (satu baris), penerima di tabel lain
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category        notif_category NOT NULL,
  title           text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 150),
  body            text NOT NULL DEFAULT '' CHECK (char_length(body) <= 500),
  -- hanya path relatif internal (cegah open-redirect / javascript: URL)
  link            text CHECK (link IS NULL OR link ~ '^[a-z0-9_.-]+\.html(\?[a-zA-Z0-9_=&%-]*)?$'),
  source_key      text UNIQUE CHECK (char_length(source_key) <= 200),          -- dedupe, mis. 'report-status:<id>:diproses'
  announcement_id uuid REFERENCES announcements(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_created_idx ON notifications (created_at DESC);

CREATE TABLE notification_recipients (
  notification_id uuid NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  read_at         timestamptz,
  PRIMARY KEY (notification_id, user_id)
);
CREATE INDEX notif_recipient_user_idx   ON notification_recipients (user_id);
CREATE INDEX notif_recipient_unread_idx ON notification_recipients (user_id) WHERE read_at IS NULL;

-- =====================================================================
-- D. LAPORAN (menyatukan modul Lapor + Keamanan + Kebersihan)
-- =====================================================================
CREATE TABLE reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id   uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  category      report_category NOT NULL,
  title         text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 100),
  description   text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 1 AND 1200),
  location_text text NOT NULL CHECK (char_length(btrim(location_text)) BETWEEN 1 AND 120),
  block_id      smallint REFERENCES blocks(id) ON DELETE SET NULL,           -- opsional, utk filter per blok
  incident_date date NOT NULL DEFAULT CURRENT_DATE,
  recipient     report_recipient,                                            -- dipakai modul Kebersihan
  status        report_status NOT NULL DEFAULT 'dikirim',
  handled_by    uuid REFERENCES users(id) ON DELETE SET NULL,                -- admin penindak
  admin_note    text CHECK (char_length(admin_note) <= 1000),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  CHECK (recipient IS NULL OR category = 'kebersihan')
);
CREATE INDEX reports_reporter_idx ON reports (reporter_id, created_at DESC);   -- tab "Riwayat Laporan"
CREATE INDEX reports_list_idx     ON reports (created_at DESC);
CREATE INDEX reports_status_idx   ON reports (status, category);
CREATE TRIGGER reports_updated BEFORE UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE report_status_history (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  report_id   uuid NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
  from_status report_status,
  to_status   report_status NOT NULL,
  changed_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  note        text CHECK (char_length(note) <= 1000),
  changed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX report_history_idx ON report_status_history (report_id, changed_at);

-- =====================================================================
-- E. FASILITAS (ambulans, lapangan, mushola)
-- =====================================================================
CREATE SEQUENCE facility_code_seq;
CREATE TABLE facility_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code             text NOT NULL UNIQUE DEFAULT ('FAC-' || lpad(nextval('facility_code_seq')::text, 6, '0')),
  facility         facility_type NOT NULL,
  requester_id     uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  -- snapshot data pemohon saat mengajukan
  applicant_name   text NOT NULL CHECK (char_length(applicant_name) BETWEEN 2 AND 100),
  applicant_phone  text NOT NULL CHECK (applicant_phone ~ '^[0-9]{8,15}$'),
  address_text     text NOT NULL CHECK (char_length(address_text) BETWEEN 1 AND 100),
  use_date         date NOT NULL,
  start_time       time NOT NULL,
  end_time         time,                                                   -- NULL utk ambulans
  purpose          text NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 1 AND 80),
  -- rincian ambulans
  pickup_location  text CHECK (char_length(pickup_location) <= 200),
  destination      text CHECK (char_length(destination) <= 200),
  patient_count    smallint CHECK (patient_count BETWEEN 1 AND 5),
  -- rincian lapangan / mushola
  participant_count smallint CHECK (participant_count BETWEEN 1 AND 300),
  notes            text CHECK (char_length(notes) <= 500),
  status           request_status NOT NULL DEFAULT 'menunggu_konfirmasi',
  decided_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  decided_at       timestamptz,
  decision_note    text CHECK (char_length(decision_note) <= 500),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  -- rentang waktu (hanya lapangan/mushola) untuk deteksi bentrok
  period           tsrange GENERATED ALWAYS AS (
                     CASE WHEN end_time IS NOT NULL AND end_time > start_time
                          THEN tsrange(use_date + start_time, use_date + end_time) END) STORED,
  CONSTRAINT ambulans_rules CHECK (facility <> 'ambulans' OR
      (pickup_location IS NOT NULL AND destination IS NOT NULL AND patient_count IS NOT NULL
       AND end_time IS NULL AND participant_count IS NULL)),
  CONSTRAINT venue_rules CHECK (facility = 'ambulans' OR
      (end_time IS NOT NULL AND end_time > start_time AND participant_count IS NOT NULL
       AND pickup_location IS NULL AND destination IS NULL AND patient_count IS NULL)),
  CONSTRAINT lapangan_max CHECK (facility <> 'mushola' OR participant_count <= 200),
  -- dua pengajuan DISETUJUI untuk fasilitas yang sama tidak boleh beririsan waktu
  CONSTRAINT no_double_booking EXCLUDE USING gist
      (facility WITH =, period WITH &&) WHERE (status = 'disetujui' AND period IS NOT NULL)
);
CREATE INDEX facility_req_user_idx   ON facility_requests (requester_id, created_at DESC);
CREATE INDEX facility_req_status_idx ON facility_requests (status, use_date);
CREATE TRIGGER facility_requests_updated BEFORE UPDATE ON facility_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- F. KEAMANAN: petugas, shift, SIGAP
-- =====================================================================
CREATE TABLE security_guards (            -- tepat 2 slot (petugas 1 & 2) sesuai halaman Keamanan
  slot        smallint PRIMARY KEY CHECK (slot IN (1, 2)),
  name        text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 2 AND 60),
  phone       text CHECK (phone ~ '^[0-9]{8,15}$'),
  updated_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE security_shift_config (      -- baris tunggal
  id           boolean PRIMARY KEY DEFAULT true CHECK (id),
  shift_start  time NOT NULL DEFAULT '07:00',
  shift_hours  smallint NOT NULL DEFAULT 12 CHECK (shift_hours BETWEEN 1 AND 24),
  configured   boolean NOT NULL DEFAULT false,
  updated_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sigap_alerts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES users(id) ON DELETE RESTRICT,           -- NULL = anonim (lihat catatan di README)
  unit_id         integer REFERENCES units(id) ON DELETE SET NULL,
  contact_name    text CHECK (char_length(contact_name) <= 100),
  contact_phone   text CHECK (contact_phone ~ '^[0-9]{8,15}$'),
  message         text CHECK (char_length(message) <= 300),
  status          sigap_status NOT NULL DEFAULT 'terkirim',
  ip              inet,
  created_at      timestamptz NOT NULL DEFAULT now(),
  acknowledged_at timestamptz, acknowledged_by uuid REFERENCES users(id) ON DELETE SET NULL,
  dispatched_at   timestamptz,                                              -- satpam menuju lokasi
  resolved_at     timestamptz,  resolved_by     uuid REFERENCES users(id) ON DELETE SET NULL,
  resolution_note text CHECK (char_length(resolution_note) <= 1000),
  CHECK (user_id IS NOT NULL OR contact_name IS NOT NULL)
);
CREATE INDEX sigap_status_idx ON sigap_alerts (status, created_at DESC);
-- satu pengguna hanya boleh punya 1 alarm aktif (cegah spam tombol)
CREATE UNIQUE INDEX sigap_one_active_per_user ON sigap_alerts (user_id)
  WHERE user_id IS NOT NULL AND status IN ('terkirim', 'diterima', 'menuju_lokasi');

-- =====================================================================
-- G. IURAN
-- =====================================================================
CREATE TABLE dues_bills (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id     integer NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
  period      date NOT NULL CHECK (period = date_trunc('month', period)::date),   -- tgl 1 tiap bulan
  amount_idr  numeric(12,0) NOT NULL CHECK (amount_idr >= 0),
  due_date    date NOT NULL,
  status      bill_status NOT NULL DEFAULT 'belum_dibayar',
  paid_at     timestamptz,
  verified_by uuid REFERENCES users(id) ON DELETE SET NULL,
  note        text CHECK (char_length(note) <= 500),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (unit_id, period),
  CHECK (status <> 'lunas' OR paid_at IS NOT NULL)
);
CREATE TRIGGER dues_bills_updated BEFORE UPDATE ON dues_bills FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- H. KOMUNITAS (feed warga)  — disimpulkan dari community.css karena community.js tidak ada di zip
-- =====================================================================
CREATE TABLE posts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id   uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body        text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 1000),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  deleted_by  uuid REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX posts_feed_idx   ON posts (created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX posts_author_idx ON posts (author_id);
CREATE TRIGGER posts_updated BEFORE UPDATE ON posts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE post_media (                  -- maks. 4 file per postingan (posisi 1..4)
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id     uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  position    smallint NOT NULL CHECK (position BETWEEN 1 AND 4),
  kind        media_type NOT NULL,
  mime_type   text NOT NULL CHECK (mime_type IN
                ('image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm')),
  -- nama file DIBUAT SERVER (uuid + ekstensi); nama asli dari user tidak pernah dipakai di path
  storage_key text NOT NULL UNIQUE CHECK (storage_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|gif|mp4|webm)$'),
  size_bytes  integer NOT NULL CHECK (size_bytes BETWEEN 1 AND 52428800),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (post_id, position),
  CHECK ((kind = 'image' AND mime_type LIKE 'image/%') OR (kind = 'video' AND mime_type LIKE 'video/%'))
);
CREATE TABLE post_likes (
  post_id    uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);
CREATE INDEX post_likes_user_idx ON post_likes (user_id);
CREATE TABLE post_comments (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  author_id  uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body       text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX post_comments_post_idx ON post_comments (post_id, created_at) WHERE deleted_at IS NULL;

-- =====================================================================
-- I. AUDIT (append-only; pengamanan di 03)
-- =====================================================================
CREATE TABLE audit_logs (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  actor_id    uuid,                          -- sengaja tanpa FK: log tetap utuh walau akun dianonimkan
  actor_role  text,
  ip          inet,
  action      text NOT NULL,                 -- INSERT | UPDATE | DELETE | LOGIN_FAILED | ...
  entity      text NOT NULL,
  entity_id   text,
  details     jsonb
);
CREATE INDEX audit_entity_idx ON audit_logs (entity, entity_id, occurred_at DESC);
CREATE INDEX audit_actor_idx  ON audit_logs (actor_id, occurred_at DESC);
