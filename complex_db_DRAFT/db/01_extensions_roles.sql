-- =====================================================================
-- COMPLEX — 01: ekstensi & role database
-- Dijalankan oleh superuser / pemilik database (migrasi), BUKAN oleh aplikasi.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- crypt()/gen_salt() untuk seed admin
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- exclusion constraint: cegah jadwal fasilitas bentrok

-- Role yang dipakai aplikasi (backend). Tanpa SUPERUSER, CREATEDB, CREATEROLE.
-- Password diatur terpisah:  ALTER ROLE complex_app WITH LOGIN PASSWORD '...';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'complex_app') THEN
    CREATE ROLE complex_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END $$;

-- Batasi waktu query agar injeksi/kueri berat tidak menggantung server.
ALTER ROLE complex_app SET statement_timeout = '15s';
ALTER ROLE complex_app SET idle_in_transaction_session_timeout = '30s';
