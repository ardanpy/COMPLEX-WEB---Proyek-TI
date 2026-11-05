# Role, Hak Akses, dan Beranda per Role

Halaman frontend belum ada untuk tiap role, jadi dokumen ini hanya mengikat **data & hak akses**. Pemetaan ke halaman menyusul.
Semua aturan ditegakkan di DB (RLS + trigger); backend tetap wajib mengecek, tetapi bug otorisasi tidak membocorkan data lintas role.

## 1. Tiga role
| | admin | warga | guest (tamu) |
|---|---|---|---|
| Dibuat oleh | skrip pemilik DB (admin pertama) / admin | admin | admin |
| Punya rumah (`unit_id`) | tidak | wajib | **tidak boleh** (tujuan dipilih per laporan) |
| Masa berlaku | tanpa batas | tanpa batas | `access_expires_at`, maks 7 hari dari saat diset |
| Login pertama | OTP email | OTP email | OTP email |

## 2. Matriks hak (yang ditegakkan DB)
| Data | admin | warga | guest |
|---|---|---|---|
| Pengumuman, acara (beranda) | baca + kelola | baca | **baca** |
| Blok & rumah (referensi) | baca + kelola | baca | **baca** (untuk memilih rumah tujuan) |
| Lapor Tamu | semua | milik sendiri + tamu rumahnya | **hanya milik sendiri** |
| Laporan warga, komunitas, fasilitas, SIGAP, iuran, satpam, daftar anggota | sesuai fitur | sesuai fitur | **tidak ada akses** |
| Notifikasi | miliknya | miliknya | tidak menerima (pengumuman tidak di-fanout ke tamu) |
| Ubah profil sendiri | ya | ya | ya (nama, telepon, foto) |
| Ubah masa akses / rumah / status akun | ya | tidak | tidak |
| Mendaftarkan akun | ya | tidak | tidak |

Tamu yang masa aksesnya lewat dianggap **tidak ada** oleh RLS walau cookie/sesi lamanya belum dibuang (cek langsung ke `users.access_expires_at`).

## 3. Lapor Tamu 1x24 jam (`guest_visits`)
Beranda tamu hanya berisi berita komplek dan satu tombol utama **Lapor Tamu**. Pemetaan kolom form:
| Isian form | Kolom | Catatan |
|---|---|---|
| Nama | `visitor_name` | wajib |
| Alamat | `visitor_address` | alamat asal tamu, wajib |
| Tujuan: rumah | `host_unit_id` | dipilih dari blok + nomor rumah (`blocks`/`units` dapat dibaca tamu), wajib |
| Tujuan: warga | `host_name` | teks bebas, opsional; daftar warga **tidak** dibuka ke tamu (privasi) |
| Keperluan | `purpose` | wajib |
| (opsional) | `visitor_phone`, `vehicle_plate`, `visit_start` | |

- Pelapor: tamu (rumah tujuan bebas dipilih), warga (untuk tamunya; rumah tujuan wajib rumahnya sendiri), atau admin.
- `valid_until = visit_start + 24 jam` dihitung trigger; nilai dari klien diabaikan. Waktu kunjungan boleh dari 1 jam lalu sampai 24 jam ke depan.
- Setelah 24 jam laporan otomatis tidak aktif (`v_guest_visits.is_active = false`). Tidak ada perpanjangan: buat laporan baru.
- Batas: tamu maks 1 laporan aktif; warga maks 10.
- Isi laporan tidak bisa diubah; hanya `aktif → selesai | dibatalkan` oleh pelapor/admin (kolom `status` saja yang boleh di-UPDATE).
- Saat laporan dibuat: admin dan penghuni rumah tujuan dinotifikasi (`link = tamu.html`).
- Tidak menyimpan NIK/KTP tamu (minimisasi data, UU PDP). Yang disimpan: nama, telepon opsional, plat opsional, tujuan.

## 4. Alur setelah login → beranda
```
POST /auth/login  → (OTP bila perlu) → sesi
GET  /home        → backend: fn_session_user(sha256(cookie)) → set_config('app.user_id', uid, true) → SELECT fn_home()
```
`fn_home()` mengembalikan `jsonb` (atau `NULL` bila sesi tidak sah/tamu kedaluwarsa → backend balas 401):
```json
{
  "user": {"id","full_name","role","unit":{"block","house_number"},"photo_storage_key","access_expires_at"},
  "landing": "beranda_admin | beranda_warga | beranda_tamu",
  "announcements": [{"id","category","title","excerpt","is_pinned","published_at"}],   // maks 10
  "events": [{"id","title","location","starts_at","ends_at"}],                          // yang belum lewat, maks 10
  "stats": { ...bergantung role... }
}
```
| Role | isi `stats` |
|---|---|
| admin | `reports_new`, `reports_in_progress`, `facility_pending`, `sigap_open`, `dues_awaiting_verification`, `guests_active`, `accounts_not_activated`, `unread_notifications` |
| warga | `unread_notifications`, `my_open_reports`, `my_pending_facility`, `my_unpaid_dues`, `guests_at_my_unit` |
| guest | `primary_action = "lapor_tamu"` (tombol utama), `my_active_visit` (`id`, `visitor_name`, `visit_start`, `valid_until`, atau `null`) |

`landing` adalah kunci logis; frontend memetakannya ke halaman. Payload tidak memuat email/hash.

## 4b. Wajib di backend
- Atur `app.user_id` dengan `set_config(..., true)` (lokal transaksi) sebelum query apa pun yang butuh RLS.
- Login: tolak (pesan generik) bila `role='guest'` dan `access_expires_at <= now()`.
- Muat sesi hanya lewat `fn_session_user`, jangan membaca role dari cookie/JWT.
- Membuat akun tamu (admin): isi `role='guest'`, `access_expires_at`, `created_by` (tanpa `unit_id`); password sementara dibuat backend; tamu tetap lewat OTP login pertama.

## 5. Asumsi yang dipakai (mohon dikonfirmasi tim)
1. Akun tamu **dibuat admin**, bukan daftar mandiri (konsisten dengan aturan "tanpa pendaftaran mandiri").
2. "Lapor tamu 1x24 jam" = laporan kunjungan yang berlaku 24 jam; diajukan tamu lewat form di beranda (warga tuan rumah juga boleh melaporkan tamunya).
5. Tamu tetap punya akun (login oleh admin-terdaftar). Bila timmu menginginkan tamu **tanpa akun** (form publik di gerbang), itu desain lain; beri tahu.
3. Masa akses akun tamu maksimal 7 hari (dapat diubah di `trg_users_guard`).
4. Tamu tidak mendapat notifikasi, SIGAP, atau fitur komunitas.
