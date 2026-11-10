# Role Security (Satpam) — FINAL

Status: final untuk cakupan di bawah. Rancangan awal (kasus keamanan, SIGAP) disimpan di `db/optional/10b_security_cases.sql`;
catatan lama di `docs/SECURITY_ROLE_OLD_PLAN.md`.

## Fitur satpam
| Menu | Isi | Endpoint |
|---|---|---|
| Absen masuk | foto wajib (kamera), jam dari **server** | `POST /security/attendance/check-in` (multipart `photo`, `note?`) |
| Absen pulang | foto wajib, jam dari server | `POST /security/attendance/check-out` |
| Status & riwayat | sedang bertugas? riwayat + durasi | `GET /security/attendance/status`, `GET /security/attendance` |
| Laporan masalah warga | daftar + detail, filter status/kategori | `GET /security/reports`, `GET /security/reports/{id}` |
| Ubah status laporan | `diproses` / `selesai` / `ditolak` + catatan | `PATCH /security/reports/{id}/status` → `fn_security_set_report_status(id, status, note)` |
| Tamu aktif (gerbang) | Lapor Tamu yang masih berlaku, hanya baca | `GET /security/guests` |
| Foto absen | hanya pemilik atau admin | `GET /files/attendance/:key` |

## Aturan yang ditegakkan DB
- Akun dibuat admin, tanpa rumah, aktivasi OTP seperti warga.
- Satu absen terbuka per akun; foto wajib saat masuk dan pulang; absen pulang tidak bisa diubah; kunci foto hanya `uuid.jpg|png|webp`.
- Security hanya melihat absennya sendiri; admin melihat semua (`v_security_attendance`).
- Laporan warga: `v_reports_for_security` (nama pelapor saja, tanpa telepon/email/catatan admin).
- Satpam mengubah status HANYA lewat `fn_security_set_report_status` (migrasi 12): hanya kolom status berubah; tidak bisa kembali ke `dikirim`;
  tidak bisa membuka ulang laporan `selesai`/`ditolak` (wewenang admin). Hasil fungsi: `ok|forbidden|invalid|not_found|closed|unchanged`.
- Log untuk admin: `report_status_history` (pelaku, dari-ke, catatan, waktu server), `v_report_status_log` (+ nama & role pelaku, hanya admin), dan `audit_logs`.
  Warga pelapor otomatis dinotifikasi saat status berubah.
- Satpam bukan anggota komunitas: tidak bisa membaca/memposting komunitas, membuat laporan, atau menekan SIGAP (migrasi 12).

## Keputusan yang saya ambil (ubah bila tim berbeda)
Satpam tidak boleh membuka ulang laporan yang sudah selesai/ditolak (hanya admin); satpam boleh menolak laporan.
Kasus keamanan, progres, dan SIGAP untuk satpam **tidak** masuk cakupan final (permintaan tim hanya absen + lihat laporan); jam shift/GPS tidak dipakai (hanya foto + timestamp server + durasi); slot petugas (`security_guards.user_id`) dapat ditautkan ke akun security; satu akun per petugas; retensi foto belum diputuskan.
