-- =====================================================================
-- COMPLEX — 06: foto profil pengguna
-- File gambar TIDAK disimpan di DB. DB hanya menyimpan kunci file yang dibuat SERVER
-- (uuid + ekstensi). Nama file dari pengguna tidak pernah dipakai (anti path traversal).
-- Backend wajib: cek magic bytes (bukan hanya ekstensi/MIME header), batasi ukuran (mis. 2 MB),
-- re-encode gambar (membuang EXIF/GPS), dan sajikan lewat endpoint yang mewajibkan login.
-- =====================================================================
ALTER TABLE users
  ADD COLUMN photo_storage_key text
    CHECK (photo_storage_key IS NULL OR photo_storage_key ~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$');

GRANT UPDATE (photo_storage_key) ON users TO complex_app;
