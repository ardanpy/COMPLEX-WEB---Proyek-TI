# Workflow Login (email + password + OTP email)

Prinsip: akun hanya dibuat admin; tanpa daftar mandiri, tanpa login Google/pihak ketiga; NIK tidak dipakai.
Diagram: `docs/auth_flow.png` (sumber `docs/auth_flow.mmd`).

## Dua alur, satu mesin OTP
| Alur | Pemicu | Syarat akun | Hasil |
|---|---|---|---|
| Aktivasi (login pertama) | email + password sementara dari admin benar | `activated_at IS NULL`, belum lewat `activation_expires_at` (7 hari) | OTP → tiket → set password → akun aktif |
| Lupa password | `/auth/forgot` | sudah aktif, `status='aktif'` | OTP → tiket → set password |

## Endpoint untuk backend
| Endpoint | Fungsi DB | Catatan |
|---|---|---|
| `POST /auth/login` | query `users`, `fn_login_failed/succeeded`, INSERT `sessions` | akun belum aktif → balas `{next:"otp"}`, tanpa sesi |
| `POST /auth/activate/request-otp` | `fn_otp_issue(.., 'activation', ..)` | dipanggil setelah login pertama lolos |
| `POST /auth/forgot` | `fn_otp_issue(.., 'password_reset', ..)` | respons SELALU generik |
| `POST /auth/{activate,reset}/verify-otp` | `fn_otp_verify` | `ok` → kembalikan tiket acak (DB simpan SHA-256-nya) |
| `POST /auth/set-password` | `fn_set_password` | backend hash Argon2id, kebijakan ≥ 12 karakter |
| `GET /auth/me` | `fn_session_user(sha256(cookie))` | satu pintu: cek sesi, status, aktivasi, masa akses tamu |
| `GET /home` | `fn_home()` (set `app.user_id` dulu) | beranda sesuai role, lihat `docs/ROLES_AND_HOME.md` |
| `POST /auth/logout`, `POST /auth/change-password` | `sessions`, `users` | role selalu dari DB |
| `POST /admin/users/:id/reset-password` | `fn_admin_reset_password` | password sementara dibuat backend, dikirim admin lewat jalur lain, bukan email |

Status hasil fungsi: `fn_otp_issue` → `ok|ineligible|cooldown|limit`; `fn_otp_verify` → `ok|invalid|expired|locked`.
Ke klien semuanya diterjemahkan menjadi pesan generik (jangan bedakan "email tak ada" vs "akun tak eligible").

## Aturan OTP (ditegakkan di DB)
- 6 digit, berlaku 10 menit, disimpan sebagai HMAC-SHA256 (pepper hanya di env backend, TIDAK di DB).
- Maks 5 tebakan salah per kode → terkunci; kode benar sesudahnya tetap ditolak.
- 1 kode aktif per (user, tujuan); cooldown 60 detik; maks 5/jam dan 10/hari.
- OTP benar → tiket sekali pakai 10 menit; `fn_set_password` menyetel password, mengaktifkan akun, reset lockout, mencabut semua sesi, dan menulis audit.
- Role `complex_app` tidak punya akses langsung ke `otp_challenges`/`auth_tokens`, dan tidak bisa mengisi `activated_at`.

## Wajib di sisi backend
1. Pepper HMAC dari env (≥ 32 byte acak), bukan hardcode.
2. Email OTP hanya berisi kode + masa berlaku; jangan pernah memuat password.
3. Rate limit per IP di depan DB (batas DB per akun tidak menggantikannya).
4. Cookie sesi: `HttpOnly; Secure; SameSite=Lax/Strict`, token acak ≥ 32 byte, simpan SHA-256; CSRF token untuk request mengubah data.
5. Samakan waktu respons untuk email tak dikenal (hash dummy), seperti di `tests/login_sim.py`.
6. Admin pertama dibuat lewat `scripts/create_admin.sh` oleh pemilik DB.

## Pengujian
`tests/run.sh` (191 asersi SQL) dan `tests/run_sim.sh` (49 asersi alur backend + serangan). Sim selalu membuat DB baru karena mengubah data.
