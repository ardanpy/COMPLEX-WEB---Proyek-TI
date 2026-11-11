<?php

namespace App\Http\Controllers;

use App\Support\Db;
use App\Support\ImageSanitizer;
use App\Support\Tok;
use App\Support\UploadException;
use Illuminate\Database\QueryException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;

/** Role security (satpam): absen foto, laporan warga (lihat + ubah status), tamu aktif. Detail: docs/SECURITY_ROLE.md */
class SecurityController extends Controller
{
    private const STATUSES = ['dikirim', 'diproses', 'selesai', 'ditolak'];
    private const CATS = ['kebersihan', 'fasilitas', 'keamanan', 'lainnya'];

    private function me(Request $r): object { return $r->attributes->get('auth'); }
    private function int(Request $r, string $k, int $d, int $min, int $max): int
    {
        $n = filter_var($r->query($k), FILTER_VALIDATE_INT);
        return $n === false ? $d : max($min, min($max, $n));
    }
    private function note(Request $r): ?string
    {
        $n = $r->input('note'); if (!is_string($n)) return null;
        $n = mb_substr(trim($n), 0, 300); return $n === '' ? null : $n;
    }
    /** Foto dibersihkan lalu disimpan dengan nama acak. Mengembalikan kunci berkas. */
    private function storePhoto(Request $r): string
    {
        $f = $r->file('photo');
        if (!$f || !$f->isValid()) throw new UploadException('Foto wajib diunggah.');
        $jpg = ImageSanitizer::clean(file_get_contents($f->getRealPath()));
        $key = ImageSanitizer::newKey();
        Storage::disk('local')->put("attendance/$key", $jpg);
        return $key;
    }
    private function dropPhoto(string $key): void { Storage::disk('local')->delete("attendance/$key"); }

    // ---------- Absen ----------
    public function status(Request $r): JsonResponse
    {
        $a = $this->me($r);
        $row = Db::as($a->id, fn () => DB::selectOne('select check_in_at from security_attendance where user_id = ?::uuid and check_out_at is null', [$a->id]));
        return response()->json(['on_duty' => (bool) $row, 'since' => $row->check_in_at ?? null, 'server_time' => now()->toIso8601String()]);
    }

    public function checkIn(Request $r): JsonResponse
    {
        $a = $this->me($r);
        try { $key = $this->storePhoto($r); } catch (UploadException $e) { return response()->json(['error' => $e->getMessage()], 400); }
        try {
            // check_in_at TIDAK dikirim klien: diisi jam server oleh trigger.
            $row = Db::as($a->id, fn () => DB::selectOne(
                'insert into security_attendance (user_id, check_in_photo_key, note) values (?::uuid, ?, ?) returning id, check_in_at',
                [$a->id, $key, $this->note($r)]));
        } catch (QueryException $e) {
            $this->dropPhoto($key);
            if ($e->getCode() === '23505') return response()->json(['error' => 'Anda sudah absen masuk dan belum absen pulang.'], 409);
            throw $e;
        }
        return response()->json(['ok' => true, 'id' => $row->id, 'check_in_at' => $row->check_in_at], 201);
    }

    public function checkOut(Request $r): JsonResponse
    {
        $a = $this->me($r);
        try { $key = $this->storePhoto($r); } catch (UploadException $e) { return response()->json(['error' => $e->getMessage()], 400); }
        try {
            $row = Db::as($a->id, fn () => DB::selectOne(
                'update security_attendance set check_out_photo_key = ?, note = coalesce(?, note)
                  where user_id = ?::uuid and check_out_at is null returning id, check_in_at, check_out_at',
                [$key, $this->note($r), $a->id]));
        } catch (\Throwable $e) { $this->dropPhoto($key); throw $e; }
        if (!$row) { $this->dropPhoto($key); return response()->json(['error' => 'Belum ada absen masuk yang terbuka.'], 409); }
        return response()->json(['ok' => true, 'id' => $row->id, 'check_in_at' => $row->check_in_at, 'check_out_at' => $row->check_out_at]);
    }

    public function attendance(Request $r): JsonResponse
    {
        $a = $this->me($r); $limit = $this->int($r, 'limit', 30, 1, 100); $offset = $this->int($r, 'offset', 0, 0, 100000);
        $rows = Db::as($a->id, fn () => DB::select(
            'select id, check_in_at, check_in_photo_key, check_out_at, check_out_photo_key, note, on_duty, duration_minutes
               from v_security_attendance where user_id = ?::uuid order by check_in_at desc limit ? offset ?', [$a->id, $limit, $offset]));
        return response()->json(['items' => $rows]);
    }

    // ---------- Laporan warga ----------
    public function reports(Request $r): JsonResponse
    {
        $a = $this->me($r); $status = $r->query('status'); $cat = $r->query('category');
        if ($status !== null && !in_array($status, self::STATUSES, true)) return response()->json(['error' => 'Status tidak valid.'], 400);
        if ($cat !== null && !in_array($cat, self::CATS, true)) return response()->json(['error' => 'Kategori tidak valid.'], 400);
        $limit = $this->int($r, 'limit', 20, 1, 100); $offset = $this->int($r, 'offset', 0, 0, 100000);
        $rows = Db::as($a->id, fn () => DB::select(
            'select v.id, v.category, v.title, v.description, v.location_text, b.name as block, v.incident_date, v.status, v.reporter_name, v.created_at
               from v_reports_for_security v left join blocks b on b.id = v.block_id
              where (?::report_status is null or v.status = ?::report_status) and (?::report_category is null or v.category = ?::report_category)
              order by v.created_at desc limit ? offset ?', [$status, $status, $cat, $cat, $limit, $offset]));
        return response()->json(['items' => $rows]);
    }

    public function report(Request $r, string $id): JsonResponse
    {
        if (!Tok::isUuid($id)) return response()->json(['error' => 'ID tidak valid.'], 400);
        $a = $this->me($r);
        $row = Db::as($a->id, fn () => DB::selectOne(
            'select v.id, v.category, v.title, v.description, v.location_text, b.name as block, v.incident_date, v.status, v.reporter_name, v.created_at, v.updated_at
               from v_reports_for_security v left join blocks b on b.id = v.block_id where v.id = ?::uuid', [$id]));
        return $row ? response()->json($row) : response()->json(['error' => 'Laporan tidak ditemukan.'], 404);
    }

    /** Satpam mengubah status HANYA lewat fungsi DB (migrasi 12): jejak riwayat + audit + notifikasi warga otomatis. */
    public function setReportStatus(Request $r, string $id): JsonResponse
    {
        $status = $r->input('status'); $note = $r->input('note');
        if (!Tok::isUuid($id) || !in_array($status, ['diproses', 'selesai', 'ditolak'], true) || ($note !== null && (!is_string($note) || mb_strlen($note) > 1000))) {
            return response()->json(['error' => 'Data tidak valid.'], 400);
        }
        $a = $this->me($r);
        $st = Db::as($a->id, fn () => DB::selectOne('select fn_security_set_report_status(?::uuid, ?::report_status, ?) as st', [$id, $status, $note])->st);
        return match ($st) {
            'ok'        => response()->json(['ok' => true]),
            'not_found' => response()->json(['error' => 'Laporan tidak ditemukan.'], 404),
            'closed'    => response()->json(['error' => 'Laporan sudah selesai/ditolak; hanya admin yang dapat membukanya kembali.'], 409),
            'unchanged' => response()->json(['error' => 'Status sudah sama.'], 409),
            'forbidden' => response()->json(['error' => 'Tidak punya akses.'], 403),
            default     => response()->json(['error' => 'Data tidak valid.'], 400),
        };
    }

    // ---------- Tamu aktif (cek di gerbang) ----------
    public function guests(Request $r): JsonResponse
    {
        $a = $this->me($r);
        $rows = Db::as($a->id, fn () => DB::select(
            "select g.id, g.visitor_name, g.visitor_address, g.vehicle_plate, b.name as host_block, g.host_house, g.host_name, g.purpose, g.visit_start, g.valid_until
               from guest_visits g join blocks b on b.id = g.host_block_id
              where g.status = 'aktif' and g.valid_until > now() order by g.created_at desc limit 100"));
        return response()->json(['items' => $rows]);
    }

    // ---------- Berkas foto absen: pemilik atau admin (disaring RLS lewat view) ----------
    public function attendancePhoto(Request $r, string $key)
    {
        $a = $this->me($r);
        if (!ImageSanitizer::validKey($key)) return response()->json(['error' => 'Tidak ditemukan.'], 404);
        $ok = Db::as($a->id, fn () => DB::selectOne(
            'select 1 as ok from v_security_attendance where check_in_photo_key = ? or check_out_photo_key = ? limit 1', [$key, $key]));
        $disk = Storage::disk('local');
        if (!$ok || !$disk->exists("attendance/$key")) return response()->json(['error' => 'Tidak ditemukan.'], 404);
        return response($disk->get("attendance/$key"), 200, [
            'Content-Type' => 'image/jpeg', 'Cache-Control' => 'private, max-age=300', 'X-Content-Type-Options' => 'nosniff']);
    }
}
