-- Akun tamu uji (DEV saja). Password: Complex#Test2026. Tamu tidak terikat rumah; tujuan dipilih saat Lapor Tamu. Akses berlaku 24 jam sejak dimuat.
INSERT INTO users (id, email, full_name, phone, role, password_hash, activated_at, access_expires_at, created_by)
VALUES ('00000000-0000-0000-0000-0000000000d1', 'tamu@complex.test', 'Tamu Contoh', '6281200000099', 'guest',
        '$argon2id$v=19$m=19456,t=2,p=1$JKiyglca9jj3vKrspTCAUw$+jAjEpk54PB+8gN8b4asvgnH7X7rk/IqBYnMbrDqvak',
        now(), now() + interval '24 hours', '00000000-0000-0000-0000-0000000000a1');
