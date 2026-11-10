-- =====================================================================
-- COMPLEX — 11: perbaikan jalur login pra-autentikasi
-- Masalah: fn_login_failed / fn_login_succeeded (03) berjalan sebagai pemanggil (complex_app). Sebelum login belum ada
-- app.user_id, sedangkan sejak 09 tabel users memakai RLS (hanya diri sendiri/admin). Akibatnya UPDATE failed_login_count /
-- locked_until / last_login_at memengaruhi 0 baris, sehingga kunci akun setelah 5 kali gagal tidak bekerja dari sisi aplikasi.
-- (Tes lama menjalankannya sebagai superuser sehingga RLS tidak terlihat.)
-- Perbaikan: jalankan sebagai pemilik (SECURITY DEFINER) dengan search_path terkunci; isi fungsi tidak berubah.
-- =====================================================================
ALTER FUNCTION fn_login_failed(uuid, text, inet, text)    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION fn_login_succeeded(uuid, text, inet, text) SECURITY DEFINER SET search_path = public, pg_temp;
