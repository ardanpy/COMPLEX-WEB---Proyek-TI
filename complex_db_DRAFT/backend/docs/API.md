# API COMPLEX (ringkas)

Semua respons JSON `{error}` saat gagal. Request pengubah data butuh header `x-csrf-token` (nilai `csrf` dari `/auth/login`) dan `Origin` frontend.

## Auth
| Metode & path | Body | Hasil |
|---|---|---|
| POST `/auth/login` | email, password, remember? | `{ok, csrf, role}` + cookie `sid`; akun belum aktif: `{next:"otp", purpose:"activation"}` dan OTP dikirim |
| POST `/auth/otp/verify` | email, purpose, code | `{ticket}` (10 menit, sekali pakai) |
| POST `/auth/otp/resend` | email, purpose, password (aktivasi) | pesan generik |
| POST `/auth/forgot` | email | pesan generik |
| POST `/auth/set-password` | ticket, password (>=12) | `{ok}` lalu login ulang |
| GET `/auth/me`, POST `/auth/logout`, POST `/auth/change-password` | | |

## Beranda
GET `/home` — admin/warga: `fn_home()`, security: `fn_home_security()`.
Tamu: POST `/guest/start` (tombol "Masuk sebagai tamu"), GET `/guest/home`, POST `/guest/report`, POST `/guest/report/:id/end`.

## Security (satpam) — lihat `../../docs/SECURITY_ROLE.md`
## Admin
POST `/admin/users` (warga/security, mengembalikan password sementara sekali), GET `/admin/users`, POST `/admin/users/:id/reset-password`,
PATCH `/admin/users/:id/status`, GET `/admin/attendance?user_id&from&to`.

## Belum dibangun (tahap berikutnya)
Lapor (warga), fasilitas, kebersihan, komunitas, iuran + bukti bayar, SIGAP, pengumuman/acara (admin), notifikasi, foto profil, unggah media komunitas.
