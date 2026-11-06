# PLAN — Peran Security (Satpam)

> **Status: PLAN (rancangan, belum final).** Semua berkas terkait diberi awalan `PLAN`. Tidak dimuat oleh `scripts/migrate.sh`
> dan tidak termasuk 214+55 tes utama. Setelah disetujui tim, dipromosikan menjadi migrasi `db/10_security_role.sql`.

| Berkas | Isi |
|---|---|
| `db/plan/PLAN_10_security_role.sql` | rancangan skema, RLS, trigger, fungsi |
| `tests/plan/PLAN_security_test.sql`, `tests/plan/run_plan.sh` | 55 tes rancangan (DB sementara `complex_plan`) |
| `docs/overview/PLAN_4_security_flow.png` (+ `.mmd`) | gambar alur |

Menjalankan: `sudo -u postgres tests/plan/run_plan.sh` (atau tanpa `sudo -u postgres` bila user Anda superuser).

## 1. Fokus utama (arahan tim)
1. **Masuk untuk membuat laporan**: security punya akun (dibuat admin, OTP login pertama seperti warga) dan membuka **kasus keamanan**.
2. **Absen security dengan foto**: absen masuk dan pulang, masing-masing wajib foto.
3. **Progres kasus**: linimasa pembaruan status + catatan + foto bukti.

## 2. Peran
| | admin | warga | tamu | **security (plan)** |
|---|---|---|---|---|
| Akun | ya | ya | tidak | **ya, dibuat admin, tanpa rumah** |
| Absen security | lihat semua | tidak | tidak | **buat & lihat milik sendiri** |
| Kasus keamanan + progres | semua, menutup kasus, menugaskan | tidak | tidak | **buat, lihat semua, tambah progres** |
| SIGAP | semua | milik sendiri | tidak | **lihat semua, menerima & menindaklanjuti** |
| Beranda | `fn_home` | `fn_home` | `fn_guest_home` | **`fn_home_security`** |

## 3. Data
**`security_attendance`** (absen)
- Jam masuk/pulang **selalu dari server** (klien tidak bisa mengirim waktu).
- `check_in_photo_key` wajib; absen pulang = mengisi `check_out_photo_key` (jam pulang otomatis). Pulang yang sudah tercatat tidak bisa diubah.
- Satu absen terbuka per akun (tidak bisa masuk dua kali sebelum pulang).
- Foto hanya `storage_key` buatan server (`uuid.jpg|png|webp`), bukan nama file/ path dari pengguna.
- Security hanya melihat absennya sendiri; admin melihat semua. `v_security_attendance` menghitung `on_duty` dan `duration_minutes`.

**`security_cases`** (kasus) + **`security_case_updates`** (progres, append-only)
- Kode otomatis `KS-2026-0001`. Sumber opsional: laporan warga (`report_id`) atau SIGAP (`sigap_id`), tidak keduanya.
- Status: `baru → ditangani ⇄ menunggu_tindak_lanjut → selesai → ditutup`. Status **hanya berubah lewat pembaruan progres** (UPDATE langsung ditolak), transisi divalidasi, `ditutup` hanya admin, kasus ditutup tidak bisa dibuka lagi.
- Linimasa tidak bisa diubah/dihapus aplikasi (tanpa grant UPDATE/DELETE).
- Penugasan: hanya admin, hanya ke akun security aktif. Pembuat security otomatis menjadi penanggung jawab.
- Notifikasi ke admin saat kasus baru dan saat selesai.

**SIGAP**: security ikut menerima notifikasi SIGAP baru, melihat semua SIGAP, dan mengubah statusnya (`diterima → menuju_lokasi → selesai`); pencatat penerima tersimpan. Warga pengirim dinotifikasi saat statusnya berubah (trigger yang sudah ada).

## 4. Yang dipakai ulang tanpa perubahan
Login email+password, OTP login pertama/lupa password, sesi server-side, lockout, audit log, notifikasi, `fn_session_user` (sudah mengembalikan `role = 'security'`), `fn_admin_reset_password` (diperluas ke security di plan).

## 5. Pertanyaan terbuka (butuh keputusan tim)
1. Apakah **laporan warga kategori keamanan** otomatis membuat kasus, atau security yang memutuskan membukanya? (Plan: security/admin membuka manual dan dapat menautkan laporan.)
2. Boleh **warga pelapor melihat progres** kasus dari laporannya (hanya status, tanpa catatan internal)? (Plan: tidak.)
3. Apakah absen perlu **lokasi (GPS/geofence)** selain foto, dan apakah perlu menghitung **terlambat** terhadap jam shift (`security_shift_config`, 2 petugas)? (Plan: hanya foto + durasi.)
4. Kaitan dengan tabel `security_guards` (2 slot nama/telepon yang ditampilkan ke warga): perlu ditautkan ke akun security? (Plan: belum.)
5. Siapa yang boleh **menutup kasus**? (Plan: admin saja.)
6. Boleh security **mengubah status laporan warga** (kategori keamanan) atau memposting pengumuman? (Plan: tidak.)
7. **Retensi foto** absen/bukti kasus (berapa lama disimpan; data pribadi petugas).
8. Satu akun per petugas (disarankan), atau akun bersama per shift? (Plan: satu akun per orang, supaya absen bermakna.)

## 6. Wajib di backend (saat dibangun)
- Unggah foto: cek magic bytes, batasi ukuran, re-encode (membuang EXIF/GPS), simpan dengan nama acak, sajikan lewat endpoint yang mewajibkan login; untuk absen, ambil dari kamera (bukan galeri) bila ingin mengurangi kecurangan.
- Setelah login, panggil `fn_home_security()` bila `role = 'security'` (jangan `fn_home`).
- Seluruh pembatasan lain sudah di DB; backend tetap memeriksa peran sebelum menampilkan menu.

## 7. Langkah promosi plan → final
1. Tim memutuskan pertanyaan di atas; sesuaikan `PLAN_10_security_role.sql`.
2. Pindahkan menjadi `db/10_security_role.sql`, tambahkan ke loop `scripts/migrate.sh`.
3. Gabungkan `PLAN_security_test.sql` ke suite utama (atau jalankan `tests/run.sh` + tes baru), perbarui README dan diagram.

## 8. Integrasi (ditambahkan)
- Memuat plan bersama skema: `DB=complex PLAN=1 ./scripts/migrate.sh` (opsional; tanpa `PLAN=1` plan tidak terpasang).
- Security dapat **membaca** Lapor Tamu (untuk cek di gerbang); `security_guards.user_id` menautkan slot petugas ke akun security.
- ERD plan: `docs/plan/PLAN_erd_security.mmd` dan `docs/overview/PLAN_5_erd_security.png`; alur login memuat cabang security (ditandai PLAN).
