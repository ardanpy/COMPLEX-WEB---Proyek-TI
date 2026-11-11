<?php

namespace App\Http\Controllers;

use App\Support\Db;
use App\Support\Tok;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

/** Tamu BUKAN akun: sesi anonim (cookie guest_sid, maksimal 24 jam). Tombol "Masuk sebagai tamu" di halaman login. */
class GuestController extends Controller
{
    private const MSG = [
        'limit' => 'Terlalu banyak percobaan. Coba lagi nanti.', 'no_session' => 'Sesi tamu berakhir. Mulai lagi dari halaman login.',
        'active_exists' => 'Anda masih memiliki laporan tamu yang aktif.', 'invalid' => 'Data tidak valid.', 'not_found' => 'Laporan tidak ditemukan.',
    ];

    private function clean(mixed $v, int $max): string { return is_string($v) ? mb_substr(trim($v), 0, $max) : ''; }
    private function ghash(Request $r): ?string { $c = $r->cookie('guest_sid'); return is_string($c) && $c !== '' ? Tok::sha256Hex($c) : null; }
    private function err(string $k, int $code): JsonResponse { return response()->json(['error' => self::MSG[$k] ?? self::MSG['invalid']], $code); }

    public function start(Request $r): JsonResponse
    {
        $token = Tok::random(32);
        $st = Db::tx(fn () => DB::selectOne("select fn_guest_session_start(decode(?, 'hex'), ?::inet, ?) as st",
            [Tok::sha256Hex($token), $r->ip(), $r->userAgent()])->st);
        if ($st !== 'ok') return $this->err($st, $st === 'limit' ? 429 : 400);
        return response()->json(['ok' => true])->withCookie(
            cookie('guest_sid', $token, 24 * 60, '/', null, (bool) config('complex.cookie_secure'), true, false, 'strict'));
    }

    public function home(Request $r)
    {
        $h = $this->ghash($r);
        $json = $h ? Db::tx(fn () => DB::selectOne("select fn_guest_home(decode(?, 'hex')) as h", [$h])->h) : null;
        if (!$json) return $this->err('no_session', 401);
        return response($json, 200, ['Content-Type' => 'application/json']);
    }

    public function report(Request $r): JsonResponse
    {
        $h = $this->ghash($r);
        if (!$h) return $this->err('no_session', 401);
        $name = $this->clean($r->input('name'), 100); $address = $this->clean($r->input('address'), 200); $purpose = $this->clean($r->input('purpose'), 300);
        $house = $this->clean($r->input('house'), 10); $blockId = filter_var($r->input('block_id'), FILTER_VALIDATE_INT);
        if ($name === '' || $address === '' || $purpose === '' || $house === '' || $blockId === false) {
            return response()->json(['error' => 'Lengkapi nama, alamat, blok/rumah tujuan, dan keperluan.'], 400);
        }
        $start = null;
        if ($r->filled('visit_start')) { try { $start = (new \DateTimeImmutable((string) $r->input('visit_start')))->format(DATE_ATOM); } catch (\Throwable) {} }
        $row = Db::tx(fn () => DB::selectOne(
            "select * from fn_guest_report_create(decode(?, 'hex'), ?, ?, ?::smallint, ?, ?, ?, ?, ?, ?::timestamptz, ?::inet)",
            [$h, $name, $address, $blockId, $house, $this->clean($r->input('host_name'), 100), $purpose,
             preg_replace('/\D/', '', $this->clean($r->input('phone'), 15)), $this->clean($r->input('plate'), 12), $start, $r->ip()]));
        if ($row->result !== 'ok') return $this->err($row->result, $row->result === 'limit' ? 429 : ($row->result === 'no_session' ? 401 : 400));
        return response()->json(['ok' => true, 'id' => $row->visit_id]);
    }

    public function end(Request $r, string $id): JsonResponse
    {
        $h = $this->ghash($r); $status = $r->input('status');
        if (!$h) return $this->err('no_session', 401);
        if (!Tok::isUuid($id) || !in_array($status, ['selesai', 'dibatalkan'], true)) return $this->err('invalid', 400);
        $st = Db::tx(fn () => DB::selectOne("select fn_guest_report_end(decode(?, 'hex'), ?::uuid, ?::visit_status) as st", [$h, $id, $status])->st);
        if ($st !== 'ok') return $this->err($st, $st === 'not_found' ? 404 : 400);
        return response()->json(['ok' => true]);
    }
}
