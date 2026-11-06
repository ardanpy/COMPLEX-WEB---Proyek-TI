# Peran, Hak Akses, dan Beranda

Halaman frontend per peran belum ada, jadi dokumen ini hanya mengikat **data & hak akses**; pemetaan ke halaman menyusul.
Aturan ditegakkan di DB (RLS, trigger, fungsi); backend tetap wajib mengecek, tetapi bug otorisasi tidak membocorkan data lintas peran.

## 1. Tiga peran: dua berakun, satu anonim
| | admin | warga | tamu |
|---|---|---|---|
| Punya akun (`users`) | ya | ya | **tidak** |
| Dibuat oleh | skrip pemilik DB / admin | admin | tidak perlu didaftarkan siapa pun |
| Login | email + password (+ OTP login pertama & lupa password) | sama | **tanpa login**: tombol "Masuk sebagai tamu" |
| Identitas | cookie sesi akun | cookie sesi akun | cookie sesi tamu `guest_sid` (acak, berlaku **24 jam**, habis = selesai) |
| Rumah (`unit_id`) | tidak | wajib | tidak ada (tujuan dipilih per laporan) |

## 2. Matriks hak (ditegakkan DB)
| Data / aksi | admin | warga | tamu |
|---|---|---|---|
| Berita komplek (pengumuman kategori `komplek`) | baca + kelola | baca (semua kategori) | **baca** (hanya `komplek`) |
| Acara, pengumuman pengurus/keamanan/kebersihan | ya | ya | tidak |
| Lapor Tamu | lihat semua | buat untuk rumahnya, lihat tamu rumahnya | **buat, lihat, akhiri milik sesinya sendiri** |
| Laporan warga, komunitas, fasilitas, SIGAP, iuran, satpam, daftar anggota | sesuai fitur | sesuai fitur | tidak ada akses |
| Notifikasi | ya | ya | tidak |
| Mendaftarkan akun, mengubah rumah/status akun | admin saja | tidak | tidak |

Tamu **tidak punya `user_id`**, sehingga tidak lolos policy RLS mana pun. Satu-satunya jalan masuknya adalah lima fungsi publik (bagian 4). Role aplikasi tidak bisa membaca `guest_sessions`.

## 3. Lapor Tamu 1x24 jam
Tamu masuk dari **halaman login** lewat tombol "Masuk sebagai tamu" (bukan dari tombol Lapor Tamu). Beranda tamu berisi **berita komplek** dan satu tombol utama **Lapor Tamu**. Pemetaan form:
| Isian form | Kolom | Catatan |
|---|---|---|
| Nama | `visitor_name` | wajib |
| Alamat | `visitor_address` | alamat asal tamu, wajib |
| Tujuan: blok + nomor rumah | `host_block_id`, `host_house` | blok dari daftar (`fn_guest_home().blocks`), nomor diketik; dinormalisasi (huruf besar, spasi dibuang) |
| Tujuan: warga | `host_name` | teks bebas, opsional (daftar warga tidak dibuka ke tamu) |
| Keperluan | `purpose` | wajib |
| Opsional | `visitor_phone`, `vehicle_plate`, `visit_start` | |

Aturan:
- Berlaku tepat **24 jam** dari `visit_start` (dihitung DB; klien tidak bisa mengirim masa berlaku). `visit_start` boleh 1 jam lalu sampai 24 jam ke depan.
- Setelah 24 jam laporan tidak aktif sendiri (`is_active = false`); perpanjangan = buat laporan baru.
- Isi laporan tidak bisa diubah; status hanya `aktif → selesai | dibatalkan`, oleh pemilik sesi.
- Nomor rumah tidak terdaftar tetap diterima (`host_unit_id` kosong); admin yang menilai. Rumah terdaftar → penghuni (warga) dinotifikasi juga.
- Admin selalu dinotifikasi (`tamu.html`).
- Warga boleh melaporkan tamunya (jalur akun) hanya untuk rumahnya sendiri.
- Tidak menyimpan NIK/KTP tamu.

### Anti-spam (endpoint publik, ditegakkan di DB)
| Batas | Nilai |
|---|---|
| Sesi tamu baru per IP | 20 / jam |
| Laporan per sesi aktif | 1 |
| Laporan per IP | 3 / jam dan 5 / 24 jam |
| Masa sesi | 24 jam (`expires_at`, maksimal 24 jam oleh CHECK) |
| IP pada laporan | dihapus setelah 30 hari (`fn_purge_expired`); sesi tamu dibuang 7 hari setelah habis |
Catatan: batas per IP efektif hanya bila backend meneruskan **IP klien asli** (proxy tepercaya). Jika satu jaringan (NAT/WiFi gerbang) dipakai bersama banyak tamu, naikkan batasnya di `fn_guest_report_create`. Tambahkan CAPTCHA/honeypot di backend bila perlu.

## 4. Alur setelah masuk → beranda
```
Admin/warga:  POST /auth/login → (OTP bila perlu) → cookie sesi
              GET /home → fn_session_user(sha256(cookie)) → set_config('app.user_id', uid, true) → SELECT fn_home()
Halaman login punya 2 jalur: form email+password, dan tombol "Masuk sebagai tamu" (tanpa akun).
Tamu:         klik "Masuk sebagai tamu" → POST /guest/start  → backend buat token acak 32 byte, simpan cookie guest_sid (HttpOnly, Secure, SameSite=Strict, Max-Age=86400)
                                   → fn_guest_session_start(sha256(token), ip, ua)
              GET  /guest/home   → fn_guest_home(sha256(token))
              POST /guest/report → fn_guest_report_create(...)
              POST /guest/report/:id/end → fn_guest_report_end(sha256(token), id, 'selesai'|'dibatalkan')
```
Fungsi tamu mengembalikan kode (`ok`, `no_session`, `active_exists`, `limit`, `invalid`, `not_found`); backend menyusun pesan ke pengguna.

### `fn_guest_home` (tamu)
```json
{"role":"guest","landing":"beranda_tamu","primary_action":"lapor_tamu","expires_at":"...",
 "announcements":[{"id","title","excerpt","is_pinned","published_at"}],
 "blocks":[{"id","name"}],
 "my_reports":[{"id","visitor_name","host_block","host_house","host_name","visit_start","valid_until","status","is_active","seconds_left"}]}
```
### `fn_home` (admin & warga)
```json
{"user":{...},"landing":"beranda_admin | beranda_warga","announcements":[...],"events":[...],"stats":{...}}
```
| Peran | isi `stats` |
|---|---|
| admin | `reports_new`, `reports_in_progress`, `facility_pending`, `sigap_open`, `dues_awaiting_verification`, `guests_active`, `accounts_not_activated`, `unread_notifications` |
| warga | `unread_notifications`, `my_open_reports`, `my_pending_facility`, `my_unpaid_dues`, `guests_at_my_unit` |

Payload tidak memuat email/hash. `landing` adalah kunci logis; frontend memetakannya ke halaman.

## 5. Wajib di backend
- Cookie tamu **terpisah** dari cookie akun; jangan gabungkan.
- `app.user_id` hanya untuk admin/warga (`set_config(..., true)` per transaksi). Jalur tamu tidak memakainya.
- Teruskan IP klien asli ke fungsi tamu (proxy tepercaya), dan rate limit tambahan di depan.
- Jangan membuat akun untuk tamu.

## 6. Asumsi (mohon dikonfirmasi tim)
1. Tamu tanpa akun, sesi 24 jam, tidak didaftarkan admin.
2. Tamu hanya melihat berita komplek, bukan acara atau pengumuman internal.
3. Nomor rumah tujuan boleh tidak terdaftar (tetap tercatat, admin menilai).
4. Pengumuman kategori `komplek` kini tampil ke siapa pun yang membuka sesi tamu: **pastikan isinya memang boleh publik**.

## Peran security (PLAN)
Rancangan peran satpam (login, absen foto, progres kasus) ada di `docs/plan/PLAN_SECURITY.md`; belum bagian dari migrasi utama.
