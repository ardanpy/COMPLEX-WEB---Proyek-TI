<?php

namespace App\Http\Controllers;

use App\Support\Db;
use App\Support\Passwords;
use App\Support\Tok;
use Illuminate\Database\QueryException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class AdminController extends Controller
{
    private function me(Request $r): object { return $r->attributes->get('auth'); }
    private function int(Request $r, string $k, int $d, int $min, int $max): int
    {
        $n = filter_var($r->query($k), FILTER_VALIDATE_INT);
        return $n === false ? $d : max($min, min($max, $n));
    }
    private function phone(mixed $p): ?string
    {
        $d = preg_replace('/\D/', '', (string) $p);
        if ($d === '') return null;
        return str_starts_with($d, '0') ? '62'.substr($d, 1) : $d;
    }

    /**
     * Admin mendaftarkan akun warga/security. Password sementara dibuat server dan ditampilkan SEKALI kepada admin
     * (diberikan lewat jalur lain, bukan email). Akun wajib aktivasi OTP email saat login pertama.
     */
    public function createUser(Request $r): JsonResponse
    {
        $a = $this->me($r);
        $role = $r->input('role'); $email = mb_strtolower(trim((string) $r->input('email'))); $name = trim((string) $r->input('full_name'));
        if (!in_array($role, ['warga', 'security'], true)) return response()->json(['error' => 'Role harus warga atau security.'], 400);
        if ($email === '' || mb_strlen($name) < 2) return response()->json(['error' => 'Email dan nama wajib diisi.'], 400);
        $temp = Passwords::temp(); $hash = Passwords::hash($temp);
        try {
            $row = Db::as($a->id, function () use ($r, $a, $role, $email, $name, $hash) {
                $unitId = null;
                if ($role === 'warga') {
                    $u = DB::selectOne('select id from units where block_id = ? and house_number = upper(?)',
                        [(int) $r->input('block_id'), trim((string) $r->input('house_number'))]);
                    if (!$u) return null;
                    $unitId = $u->id;
                }
                return DB::selectOne(
                    'insert into users (email, full_name, phone, role, unit_id, password_hash, created_by)
                     values (?, ?, ?, ?::user_role, ?, ?, ?::uuid) returning id, email, full_name, role',
                    [$email, $name, $this->phone($r->input('phone')), $role, $unitId, $hash, $a->id]);
            });
        } catch (QueryException $e) {
            if ($e->getCode() === '23505') return response()->json(['error' => 'Email sudah terdaftar.'], 409);
            if ($e->getCode() === '23514') return response()->json(['error' => 'Data tidak memenuhi aturan (cek email/telepon/nama).'], 400);
            throw $e;
        }
        if (!$row) return response()->json(['error' => 'Blok/nomor rumah tidak ditemukan.'], 400);
        return response()->json(['user' => $row, 'temp_password' => $temp,
            'note' => 'Berikan password sementara lewat jalur lain. Berlaku 7 hari; wajib OTP email saat login pertama.'], 201);
    }

    public function users(Request $r): JsonResponse
    {
        $a = $this->me($r); $limit = $this->int($r, 'limit', 50, 1, 200); $offset = $this->int($r, 'offset', 0, 0, 100000);
        $role = in_array($r->query('role'), ['admin', 'warga', 'security'], true) ? $r->query('role') : null;
        $rows = Db::as($a->id, fn () => DB::select(
            'select u.id, u.email, u.full_name, u.phone, u.role, u.status, u.activated_at, u.last_login_at, b.name as block, un.house_number
               from users u left join units un on un.id = u.unit_id left join blocks b on b.id = un.block_id
              where (?::user_role is null or u.role = ?::user_role) order by u.created_at desc limit ? offset ?', [$role, $role, $limit, $offset]));
        return response()->json(['items' => $rows]);
    }

    public function resetPassword(Request $r, string $id): JsonResponse
    {
        if (!Tok::isUuid($id)) return response()->json(['error' => 'ID tidak valid.'], 400);
        $a = $this->me($r); $temp = Passwords::temp(); $hash = Passwords::hash($temp);
        try {
            Db::as($a->id, fn () => DB::select('select fn_admin_reset_password(?::uuid, ?)', [$id, $hash]));
        } catch (QueryException $e) {
            if ($e->getCode() === '42501') return response()->json(['error' => 'Hanya admin.'], 403);
            if (stripos($e->getMessage(), 'tidak ditemukan') !== false) return response()->json(['error' => 'Akun tidak ditemukan.'], 404);
            throw $e;
        }
        return response()->json(['temp_password' => $temp, 'note' => 'Berikan lewat jalur lain (bukan email). Akun kembali ke status belum aktif dan wajib OTP.']);
    }

    public function setStatus(Request $r, string $id): JsonResponse
    {
        $st = $r->input('status');
        if (!Tok::isUuid($id) || !in_array($st, ['aktif', 'nonaktif', 'ditangguhkan'], true)) return response()->json(['error' => 'Data tidak valid.'], 400);
        $a = $this->me($r);
        $n = Db::as($a->id, function () use ($id, $st) {
            $n = DB::update("update users set status = ?::user_status where id = ?::uuid and role in ('warga','security')", [$st, $id]);
            if ($n && $st !== 'aktif') {
                DB::update("update sessions set revoked_at = now(), revoked_reason = 'status_changed' where user_id = ?::uuid and revoked_at is null", [$id]);
            }
            return $n;
        });
        return $n ? response()->json(['ok' => true]) : response()->json(['error' => 'Akun tidak ditemukan.'], 404);
    }

    /** Rekap absen seluruh security. */
    public function attendance(Request $r): JsonResponse
    {
        $uid = $r->query('user_id'); $from = $r->query('from'); $to = $r->query('to');
        $okDate = fn ($d) => $d === null || preg_match('/^\d{4}-\d{2}-\d{2}$/', (string) $d);
        if (($uid !== null && !Tok::isUuid((string) $uid)) || !$okDate($from) || !$okDate($to)) {
            return response()->json(['error' => 'Parameter tidak valid (tanggal YYYY-MM-DD).'], 400);
        }
        $a = $this->me($r); $limit = $this->int($r, 'limit', 50, 1, 200); $offset = $this->int($r, 'offset', 0, 0, 100000);
        $rows = Db::as($a->id, fn () => DB::select(
            'select id, user_id, full_name, check_in_at, check_in_photo_key, check_out_at, check_out_photo_key, note, on_duty, duration_minutes
               from v_security_attendance
              where (?::uuid is null or user_id = ?::uuid) and (?::date is null or check_in_at >= ?::date) and (?::date is null or check_in_at < ?::date + 1)
              order by check_in_at desc limit ? offset ?', [$uid, $uid, $from, $from, $to, $to, $limit, $offset]));
        return response()->json(['items' => $rows]);
    }

    /** Log perubahan status laporan (siapa, dari-ke, catatan) — admin. */
    public function reportLog(Request $r): JsonResponse
    {
        $a = $this->me($r); $limit = $this->int($r, 'limit', 50, 1, 200); $offset = $this->int($r, 'offset', 0, 0, 100000);
        $rid = $r->query('report_id');
        if ($rid !== null && !Tok::isUuid((string) $rid)) return response()->json(['error' => 'report_id tidak valid.'], 400);
        $rows = Db::as($a->id, fn () => DB::select(
            'select id, report_id, title, category, from_status, to_status, actor_name, actor_role, note, changed_at
               from v_report_status_log where (?::uuid is null or report_id = ?::uuid) order by changed_at desc limit ? offset ?',
            [$rid, $rid, $limit, $offset]));
        return response()->json(['items' => $rows]);
    }
}
