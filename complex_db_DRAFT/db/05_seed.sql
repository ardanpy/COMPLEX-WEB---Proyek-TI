-- =====================================================================
-- COMPLEX — 05: data awal WAJIB (produksi & dev). Aman dijalankan ulang.
-- =====================================================================
INSERT INTO blocks (name) SELECT 'Jati ' || g FROM generate_series(1, 7) g
ON CONFLICT (name) DO NOTHING;

INSERT INTO security_guards (slot, name) VALUES (1, 'Petugas Keamanan 1'), (2, 'Petugas Keamanan 2')
ON CONFLICT (slot) DO NOTHING;

INSERT INTO security_shift_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
