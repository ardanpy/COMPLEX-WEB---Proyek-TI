# COMPLEX — Database (PostgreSQL 16+)

Basis data untuk web pengelolaan komplek **COMPLEX** (Cluster Jati, Blok Jati 1–7), disusun dari analisis 32 berkas frontend (`Web CompleX.zip`) dan kebutuhan tim backend: **dua role (admin, warga)**, **akun hanya didaftarkan admin**, serta pengamanan terhadap SQL injection dan manipulasi cookie/sesi.

Status: skema lengkap, **140 pengujian SQL + 37 simulasi alur login/OTP lulus** (`tests/run.sh`, `tests/run_sim.sh`). Yang belum ada: API backend, penyimpanan file, pengiriman email (lihat §8).

---

## 1. Cara pakai

> Setup lokal cepat (Docker/instalasi langsung, akun uji, `.env.local`, troubleshooting): **`docs/SETUP_LOCAL.md`** → `./scripts/setup_local.sh`.

```bash
createdb complex
DB=complex ./scripts/migrate.sh                 # skema + data awal wajib (blok Jati 1–7, slot petugas)
DB=complex DEV=1 ./scripts/migrate.sh           # + data demo lengkap (HANYA dev; password demo: Demo#Password1)
DB=complex DEV=accounts ./scripts/migrate.sh    # + hanya 1 admin & 2 warga untuk uji login (password: Complex#Test2026)
psql -d complex -c "ALTER ROLE complex_app WITH LOGIN PASSWORD '<acak-panjang>'"

# admin pertama (password via prompt, di-hash Argon2id di sisi klien, tidak masuk riwayat shell)
pip install argon2-cffi
ADMIN_EMAIL=ketua@contoh.id ADMIN_NAME="Ketua RT" DB=complex ./scripts/create_admin.sh
# admin berikutnya: tambahkan email admin pembuat sebagai argumen
ADMIN_EMAIL=dua@contoh.id ADMIN_NAME="Admin Dua" DB=complex ./scripts/create_admin.sh ketua@contoh.id

sudo -u postgres tests/run.sh                   # bangun DB uji + jalankan seluruh pengujian
```

Aplikasi **hanya** boleh terhubung sebagai `complex_app` (bukan superuser/pemilik).

| Berkas | Isi |
|---|---|
| `db/01_extensions_roles.sql` | ekstensi, role `complex_app`, timeout kueri |
| `db/02_schema.sql` | 22 tabel, enum, constraint, indeks |
| `db/03_security.sql` | trigger guard, audit append-only, lockout login, notifikasi otomatis, GRANT per kolom |
| `db/04_rls.sql` | Row Level Security (isolasi data antar pengguna) |
| `db/05_seed.sql` | data awal wajib (idempoten) |
| `db/06_user_photo.sql` | kolom foto profil (kunci file buatan server) |
| `db/07_auth_otp.sql` | OTP email (aktivasi & lupa password), tiket sekali pakai, `activated_at`, fungsi DEFINER |
| `db/dev/accounts_min.sql` | akun uji: admin, budi (aktif), sari (belum aktif → wajib OTP) |
| `tests/login_sim.py`, `tests/run_sim.sh` | simulasi backend: login, OTP, lupa password, serangan — 37 asersi |
| `docs/TESTING.md`, `requirements-dev.txt` | cara menjalankan & menambah tes di lokal |
| `docs/SETUP_LOCAL.md`, `scripts/setup_local.sh`, `docker-compose.yml` | setup DB lokal satu perintah + opsi Docker |
| `docs/AUTH_WORKFLOW.md`, `docs/auth_flow.png` | workflow login lengkap + kontrak endpoint |
| `db/dev/06_demo_seed.sql` | data demo dari contoh di frontend |
| `docs/erd.png`, `docs/erd.mmd` | diagram relasi |

---

## 2. Penilaian kebutuhan & frontend (temuan penting)

### 2.1 Kesesuaian dengan kebutuhan Anda

| Kebutuhan | Kondisi frontend saat ini | Dampak ke backend |
|---|---|---|
| Akun hanya didaftarkan admin | **Tidak sesuai.** Ada `daftar.html` + `auth-register.js` (daftar mandiri) dan login Google | Hapus keduanya; DB menegakkan aturan ini (§4) |
| Role admin & warga | **Belum ada sama sekali** di frontend; tidak ada halaman admin | Perlu area admin (lihat §2.3) |
| Keamanan | Auth masih Firebase; data di `localStorage` | Diganti sesi server-side (§5) |

### 2.2 Cacat keamanan yang ditemukan di frontend

1. **Self-grant akses.** `auth-register.js` menulis sendiri `registered: true` ke dokumen `residents` dari browser, dan `auth-guard.js` mempercayai flag itu. Siapa pun yang berhasil membuat akun Firebase/Google dapat menjadikan dirinya "warga terdaftar". Dengan backend sendiri, status ini hanya boleh ditentukan server.
2. **Fitur admin terpapar ke semua orang.** Tombol "Atur petugas & jadwal shift" (`#btnManageGuards`, `keamanan.js`) tampil untuk setiap pengguna. Pada skema ini hanya admin yang dapat menulisnya (RLS + GRANT), tetapi UI harus disembunyikan.
3. **Profil warga menyimpan data pribadi di `localStorage`** (nama, telepon, email, blok, nomor rumah; ganda di kunci `cx_*`). Ambil dari endpoint `/me`, bukan penyimpanan browser.
4. **Halaman Profil mengizinkan warga mengubah blok & nomor rumah.** Karena alamat dikelola admin, kedua kolom seharusnya *read-only* bagi warga. Di DB, trigger `users_guard` menolak perubahan `unit_id`/`status` dan perubahan akun orang lain oleh non-admin (diuji), tetapi UI dan endpoint tetap harus membatasinya.
5. **Tombol SIGAP publik** (dari halaman login, tanpa login) bertentangan dengan "pengguna hanya warga & admin" dan rawan disalahgunakan. Skema mendukung keduanya; mode anonim **dimatikan** secara bawaan (§7, keputusan #1).
6. Rendering data memakai `textContent` hampir di semua tempat (bagus untuk XSS). Pertahankan; jangan beralih ke `innerHTML` untuk data dari server.

### 2.3 Kekurangan frontend yang berpengaruh pada desain data

- **Halaman admin belum ada.** Minimal dibutuhkan: manajemen warga & rumah, tinjau/ubah status laporan, setujui/tolak pengajuan fasilitas, tulis pengumuman & acara, pantau SIGAP, catat iuran, atur petugas/shift.
- **Empat berkas JS tidak ikut di zip:** `community.js`, `complex-profile.js`, `dashboard.js`, `profile.js`. Model komunitas (like, komentar, hapus post, media maks. 4, peran anggota) **disimpulkan dari `community.css`**; mohon konfirmasi dengan berkas aslinya.
- **Tiga modul laporan memakai kosakata status berbeda** (Lapor: Dikirim/Diproses/Selesai/Ditolak; Keamanan: Baru/Ditangani/Selesai; Kebersihan: Dikirim/Diproses/Selesai). Disatukan menjadi satu tabel `reports` dengan satu enum; `Baru→dikirim`, `Ditangani→diproses` (cukup dipetakan di label UI).
- Penamaan lokasi tidak konsisten (`Blok A/B/C` di `lapor.js`, `Jati 1–7` di tempat lain). Sumber kebenaran: tabel `blocks` (Jati 1–7).
- Riwayat laporan difilter dengan **nama** (`createdBy === currentUser`); harus memakai ID pengguna.
- Notifikasi dihasilkan di browser (`navigation.js`). Sekarang dihasilkan **server/trigger** dan status baca bersifat per pengguna.

---

## 3. Pilihan teknologi: PostgreSQL

Data bersifat sangat relasional (pengguna–rumah–laporan–pengajuan–notifikasi) dan butuh integritas transaksional serta constraint deklaratif. PostgreSQL dipilih karena menyediakan hal-hal yang dipakai langsung pada desain ini:

- **Exclusion constraint** (`btree_gist`) → jadwal lapangan/mushola yang bentrok ditolak *oleh database*, bukan oleh logika aplikasi yang bisa kena race condition.
- **Row Level Security** dan **hak akses per kolom** → membatasi apa yang dapat dilakukan role aplikasi.
- `CHECK` ekspresif (regex, rentang), tipe `uuid`, `inet`, `tsrange`, `jsonb`.

Firestore/MongoDB kurang cocok (relasi banyak, butuh constraint dan transaksi lintas entitas). MySQL/MariaDB bisa, tetapi **exclusion constraint dan RLS tidak tersedia**, sehingga dua jaminan itu harus dipindah ke aplikasi. Jika stack tim memaksa MySQL, beri tahu saya dan skema dapat diporting dengan perubahan tersebut.

---

## 4. Model akses: dua role & "hanya admin yang mendaftarkan"

Aturan ditegakkan di **database**, bukan hanya di API:

- Tidak ada jalur pendaftaran mandiri. `users.role` ∈ {`admin`, `warga`}; `warga` **wajib** punya `unit_id` (rumah) dan `created_by` yang merujuk **admin aktif** (CHECK + trigger).
- `complex_app` **tidak dapat** membuat akun admin, mengubah kolom `role`, mengubah `created_by`, maupun menghapus pengguna (GRANT per kolom + trigger). Admin dibuat lewat skrip pemilik DB (`create_admin.sh`). Artinya, bahkan bila aplikasi sepenuhnya dibobol, penyerang tidak bisa mencetak admin baru lewat kredensial aplikasi.
- Admin aktif terakhir tidak dapat dinonaktifkan/diturunkan.
- Akun tidak dihapus (FK `RESTRICT`); gunakan `status='nonaktif'` atau `anonymize_user()` untuk hak penghapusan data (data pribadi dibuang, riwayat tetap utuh).
- Login = **email + password** (tanpa NIK, tanpa pihak ketiga). Akun baru dari admin `activated_at IS NULL` (batas 7 hari): login pertama wajib **OTP email** lalu set password sendiri. Lupa password juga lewat OTP email. Detail: `docs/AUTH_WORKFLOW.md`.

---

## 5. Pengamanan: SQL injection, cookie, brute force

Pertahanan berlapis. Mohon dibaca bagian *batas jaminan* agar tidak salah ekspektasi.

| Lapisan | Mekanisme | Di mana |
|---|---|---|
| **App** | Query **terparameter** / ORM; tidak pernah menyusun SQL dari string input | backend (wajib) |
| **Constraint** | `CHECK` panjang/format/enum, FK, UNIQUE, nama file media dibuat server (menolak `../`), MIME allow-list, `link` notifikasi hanya path internal `*.html` (menolak `javascript:` dan URL eksternal), password plaintext ditolak (hash wajib berawalan `$argon2id$`/`$2a$`) | `02_schema.sql` |
| **Hak akses** | Role `complex_app` tanpa superuser/DDL; `UPDATE` hanya pada kolom tertentu; `audit_logs` tanpa UPDATE/DELETE; `statement_timeout 15s`; fungsi pgcrypto tidak dapat dipanggil app | `03_security.sql` |
| **RLS** | Warga hanya melihat/menulis datanya sendiri; status laporan & keputusan fasilitas hanya admin; tanpa sesi → tidak ada data bisnis | `04_rls.sql` |
| **Audit** | `audit_logs` append-only (diblokir trigger, juga untuk pemilik), hash password tidak pernah ikut tercatat | `03_security.sql` |

**Cookie / sesi (mencegah cookie injection & privilege escalation):**
- Cookie hanya berisi token acak opaque (≥128 bit). DB menyimpan **SHA-256**-nya (`sessions.token_hash`), sehingga kebocoran DB tidak memberi cookie yang valid.
- **Role tidak pernah dibaca dari cookie/JWT.** Setiap request memuat pengguna dari DB lewat sesi; mengubah isi cookie tidak dapat menaikkan hak. `app_is_admin()` juga memeriksa tabel `users`, bukan variabel sesi (diuji: memalsukan `app.user_role` tidak berpengaruh).
- Atribut cookie: `HttpOnly; Secure; SameSite=Lax/Strict; Path=/`, awalan `__Host-`. Rotasi token saat login & saat hak berubah; idle-timeout dihitung dari `last_seen_at`, batas absolut `expires_at`; "Remember 30 hari" = `remember=true` dengan `expires_at` lebih panjang. Siapkan token CSRF (`csrf_hash`) untuk metode non-GET.
- Brute force: `fn_login_failed()` mengunci akun **15 menit setelah 5 kegagalan**; `login_attempts` untuk rate-limit per IP/email. Pesan error login harus generik ("email atau password salah").

**Kontrak yang wajib dipenuhi backend pada setiap transaksi:**
```sql
BEGIN;
SELECT set_config('app.user_id', '<uuid dari sesi SERVER>', true);   -- true = hanya transaksi ini
SELECT set_config('app.ip',      '<ip klien>', true);                -- opsional, untuk audit
-- ... query bisnis (terparameter) ...
COMMIT;
```
Jangan pernah mengisi `app.user_id` dari input klien. Pakai *connection pooler* mode transaksi dengan `SET LOCAL` seperti di atas.

> **Batas jaminan (jujur):** RLS berbasis variabel sesi melindungi dari **bug otorisasi** (mis. lupa memeriksa pemilik data/IDOR). RLS **bukan** penahan penyerang yang sudah dapat mengeksekusi SQL bebas, karena ia pun dapat memanggil `set_config`. Pertahanan utama terhadap SQL injection tetap query terparameter + hak akses minimal; lapisan DB di atas hanya membatasi dampak jika pertahanan pertama gagal (misalnya tidak bisa jadi admin, tidak bisa menghapus data/audit, tidak bisa DDL). Tabel autentikasi (`users`, `sessions`, dst.) sengaja tanpa RLS karena dipakai sebelum login; perlindungannya lewat GRANT per kolom.

Hash password: **Argon2id** (m=19 MiB, t=2, p=1 — rekomendasi OWASP) dihitung di backend; DB hanya menyimpan & memvalidasi bentuknya.

---

## 6. Peta halaman frontend → tabel

| Halaman / fitur | Tabel utama | Catatan |
|---|---|---|
| Login (`index.html`) | `users`, `sessions`, `login_attempts` | Hapus kolom nama/telp/blok/no. rumah "opsional" di form login & tombol Google |
| ~~Daftar~~ | — | **Dihapus**; diganti manajemen warga oleh admin |
| Beranda: kartu profil | `users` → `units` → `blocks` | |
| Beranda: Notif Iuran | `dues_bills` | **Tentatif**: frontend hanya menampilkan status "Belum dibayar" |
| Beranda: Acara Mendatang | `events` | |
| Profil | `users` | Blok/no. rumah read-only untuk warga; "Riwayat Aktivitas" → `audit_logs` (difilter pengguna) |
| Notifikasi (Pengumuman/Komunitas/Sistem) | `notifications`, `notification_recipients`, `announcements` | Pengumuman admin otomatis di-*fan-out* ke semua pengguna aktif |
| Lapor | `reports` (+`report_status_history`) | tab "Riwayat" = `reporter_id = saya` |
| Keamanan: laporan | `reports` kategori `keamanan` | |
| Keamanan: petugas & shift | `security_guards`, `security_shift_config` | Dua slot, shift 12 jam; hanya admin yang mengubah |
| SIGAP | `sigap_alerts` | 1 alarm aktif per pengguna (anti-spam); alur 4 langkah = `terkirim→diterima→menuju_lokasi→selesai` |
| Kebersihan: laporan sampah | `reports` kategori `kebersihan` + `recipient` | Jadwal mingguan (Senin Jati 1, dst.) masih statis di HTML |
| Fasilitas (ambulans/lapangan/mushola) | `facility_requests` | Kolom bertipe per jenis + CHECK; anti-bentrok jadwal |
| Komunitas | `posts`, `post_media`, `post_likes`, `post_comments`, `v_community_members` | View anggota tanpa email/telepon |

Notifikasi otomatis (trigger): laporan dibuat/berubah status, pengajuan fasilitas dibuat/diputuskan, SIGAP dibuat/berubah, pengumuman terbit; admin juga diberi notifikasi atas laporan/pengajuan/SIGAP baru.

---

## 7. Keputusan terbuka (mohon dikonfirmasi tim)

1. **SIGAP tanpa login?** Bawaan: wajib login (`user_id` terisi). Skema mendukung anonim (`contact_name` + `contact_phone`), tetapi kebijakan RLS-nya dimatikan; jika diaktifkan wajib ada rate-limit per IP.
2. **Admin membuat admin lain dari UI?** Bawaan: hanya lewat skrip pemilik DB (paling aman). Mengizinkannya dari aplikasi berarti aplikasi yang dibobol dapat mencetak admin.
3. **Daftar laporan terlihat semua warga** (seperti UI sekarang) termasuk nama pelapor di detail? Privasi: sebaiknya nama pelapor hanya tampil untuk admin & pelapor.
4. **Iuran**: nominal tetap atau per rumah? Alur pembayaran (transfer manual + verifikasi admin, atau gateway)? Skema saat ini: tagihan bulanan per rumah dengan status `belum_dibayar/menunggu_verifikasi/lunas`.
5. **Login**: tetap pakai email? Warga tanpa email aktif perlu username/nomor rumah sebagai alternatif.
6. **Minimisasi data:** frontend menyebut "nama sesuai KTP" tetapi tidak mengumpulkan NIK; saya sengaja **tidak** menambahkan NIK (minimisasi data, UU PDP).

---

## 8. Belum dicakup (tahap berikutnya)

- API backend (autentikasi, CRUD, validasi, rate-limit, CSRF) dan penyimpanan file media (objek storage; DB hanya menyimpan `storage_key`).
- Pengiriman email OTP (DB hanya menyimpan HMAC kode; pepper di env backend) dan notifikasi *real-time* (SIGAP butuh push/WebSocket; tabel hanya menyimpan jejaknya).
- Kebijakan retensi/arsip `audit_logs` dan `login_attempts` (`fn_purge_expired()` sudah membersihkan sesi/token/percobaan login lama; jadwalkan lewat cron/pg_cron).
- Backup & enkripsi *at rest*, TLS koneksi DB (`sslmode=verify-full`).

## 9. Hasil pengujian

`tests/run.sh` membangun DB dari nol dan menjalankan 140 asersi (95 awal + 45 untuk OTP: kode terkunci setelah 5 salah, kedaluwarsa, replay tiket, batas per jam, hak akses `otp_challenges`/`auth_tokens`, reset oleh admin). `tests/run_sim.sh` menjalankan 37 asersi alur backend. Rincian 95 asersi awal: constraint & guard (13), anti-bentrok jadwal (6), laporan/notifikasi/SIGAP/lockout (12), audit append-only (5), payload injection sebagai parameter (2), hak akses minimal role aplikasi (11), isolasi RLS, guard akun & foto profil (39), login pra-autentikasi (5), anonimisasi (2). Selama pengujian ditemukan dan diperbaiki tiga cacat: (1) guard salah menganggap superuser sebagai anggota `complex_app`, (2) rentang waktu terbalik pada fasilitas ditolak oleh error mentah `tsrange` alih-alih constraint yang dimaksud, dan (3) warga ternyata masih bisa mengubah `unit_id`/`status` akunnya serta akun orang lain karena `users` tanpa RLS; kini ditutup oleh trigger guard.
