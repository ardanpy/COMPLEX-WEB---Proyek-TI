<?php

namespace App\Http\Controllers;

use App\Support\Db;
use App\Support\Passwords;
use App\Support\Tok;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cookie;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;

class AuthController extends Controller
{
    private const GENERIC_LOGIN = 'Email atau password salah.';
    private const GENERIC_OTP_REQ = 'Jika email terdaftar, kode telah dikirim.';
    private const GENERIC_OTP_BAD = 'Kode salah atau kedaluwarsa.';

    private function norm(mixed $e): string { return is_string($e) ? mb_strtolower(trim($e)) : ''; }
    private function lookup(string $email): ?object { return DB::selectOne('select * from fn_login_lookup(?)', [$email]); }
    private function err(string $m, int $code): JsonResponse { return response()->json(['error' => $m], $code); }

    private function sessionCookie(string $token, int $ttl)
    {
        return cookie('sid', $token, intdiv($ttl, 60), '/', null, (bool) config('complex.cookie_secure'), true, false, 'strict');
    }

    /** Kirim OTP; kode tidak pernah disimpan (DB hanya menyimpan HMAC). */
    private function issueOtp(Request $r, string $uid, string $email, string $purpose): string
    {
        $code = Tok::otpCode();
        $st = Db::tx(fn () => DB::selectOne(
            "select fn_otp_issue(?::uuid, ?::auth_token_purpose, decode(?, 'hex'), ?::inet) as st",
            [$uid, $purpose, Tok::otpHashHex($uid, $purpose, $code), $r->ip()]
        )->st);
        if ($st === 'ok') {
            $subject = $purpose === 'activation' ? 'Kode aktivasi akun COMPLEX' : 'Kode reset password COMPLEX';
            // Isi email hanya kode + masa berlaku. JANGAN pernah memasukkan password.
            Mail::raw("Kode Anda: $code\nBerlaku 10 menit. Jangan bagikan kode ini kepada siapa pun.", fn ($m) => $m->to($email)->subject($subject));
        }
        return (string) $st;
    }

    public function login(Request $r): JsonResponse
    {
        $email = $this->norm($r->input('email')); $password = $r->input('password'); $remember = (bool) $r->input('remember');
        if ($email === '' || !is_string($password) || strlen($password) > 200) return $this->err(self::GENERIC_LOGIN, 400);
        $ua = (string) $r->userAgent();

        $u = $this->lookup($email);
        if (!$u) {
            Passwords::burn($password);
            DB::select('select fn_login_failed(null::uuid, ?, ?::inet, ?)', [$email, $r->ip(), $ua]);
            return $this->err(self::GENERIC_LOGIN, 401);
        }
        $ok = Passwords::verify($u->password_hash, $password);
        if (!$ok || $u->status !== 'aktif' || $u->is_locked) {
            DB::select('select fn_login_failed(?::uuid, ?, ?::inet, ?)', [$u->id, $email, $r->ip(), $ua]);
            return $this->err(self::GENERIC_LOGIN, 401);
        }
        if (!$u->activated_at) {                              // login pertama: wajib OTP, belum ada sesi
            if (!$u->activation_valid) return $this->err(self::GENERIC_LOGIN, 401);
            $this->issueOtp($r, $u->id, $email, 'activation');
            return response()->json(['next' => 'otp', 'purpose' => 'activation', 'message' => 'Kode verifikasi dikirim ke email Anda.']);
        }
        $token = Tok::random(32); $csrf = Tok::random(24); $ttl = $remember ? 30 * 86400 : 8 * 3600;
        Db::tx(function () use ($u, $email, $r, $ua, $token, $csrf, $remember, $ttl) {
            DB::select('select fn_login_succeeded(?::uuid, ?, ?::inet, ?)', [$u->id, $email, $r->ip(), $ua]);
            DB::insert(
                "insert into sessions (user_id, token_hash, csrf_hash, remember, ip, user_agent, expires_at)
                 values (?::uuid, decode(?, 'hex'), decode(?, 'hex'), ?, ?::inet, left(?, 255), now() + (?::int * interval '1 second'))",
                [$u->id, Tok::sha256Hex($token), Tok::sha256Hex($csrf), $remember ? 'true' : 'false', $r->ip(), $ua, $ttl]
            );
        });
        return response()->json(['ok' => true, 'csrf' => $csrf, 'role' => $u->role])->withCookie($this->sessionCookie($token, $ttl));
    }

    public function otpResend(Request $r): JsonResponse
    {
        $email = $this->norm($r->input('email')); $purpose = $r->input('purpose');
        $u = $email !== '' ? $this->lookup($email) : null;
        if ($purpose === 'password_reset') {
            if ($u) $this->issueOtp($r, $u->id, $email, 'password_reset');
        } elseif ($purpose === 'activation') {
            if ($u && !$u->activated_at && $u->activation_valid && Passwords::verify($u->password_hash, (string) $r->input('password', ''))) {
                $this->issueOtp($r, $u->id, $email, 'activation');
            } else Passwords::burn('x');
        }
        return response()->json(['message' => self::GENERIC_OTP_REQ]);
    }

    public function forgot(Request $r): JsonResponse
    {
        $email = $this->norm($r->input('email'));
        $u = $email !== '' ? $this->lookup($email) : null;
        if ($u && $u->activated_at && $u->status === 'aktif') $this->issueOtp($r, $u->id, $email, 'password_reset');
        else Passwords::burn('x');
        return response()->json(['message' => self::GENERIC_OTP_REQ]);    // identik apa pun hasilnya
    }

    public function otpVerify(Request $r): JsonResponse
    {
        $email = $this->norm($r->input('email')); $purpose = $r->input('purpose'); $code = (string) $r->input('code', '');
        if (!in_array($purpose, ['activation', 'password_reset'], true) || !preg_match('/^[0-9]{6}$/', $code)) return $this->err(self::GENERIC_OTP_BAD, 400);
        $u = $email !== '' ? $this->lookup($email) : null;
        if (!$u) return $this->err(self::GENERIC_OTP_BAD, 400);
        $ticket = Tok::random(32);
        $st = Db::tx(fn () => DB::selectOne(
            "select fn_otp_verify(?::uuid, ?::auth_token_purpose, decode(?, 'hex'), decode(?, 'hex'), ?::inet) as st",
            [$u->id, $purpose, Tok::otpHashHex($u->id, $purpose, $code), Tok::sha256Hex($ticket), $r->ip()]
        )->st);
        if ($st !== 'ok') return $this->err(self::GENERIC_OTP_BAD, 400);    // satu pesan untuk semua kegagalan
        return response()->json(['ticket' => $ticket]);
    }

    public function setPassword(Request $r): JsonResponse
    {
        $ticket = $r->input('ticket'); $password = $r->input('password');
        if (!is_string($ticket) || strlen($ticket) < 20) return $this->err('Tiket tidak valid.', 400);
        if ($p = Passwords::problem($password)) return $this->err($p, 400);
        $uid = Db::tx(fn () => DB::selectOne("select fn_set_password(decode(?, 'hex'), ?, ?::inet) as id",
            [Tok::sha256Hex($ticket), Passwords::hash($password), $r->ip()])->id);
        if (!$uid) return $this->err('Tiket tidak valid atau kedaluwarsa.', 400);
        return response()->json(['ok' => true, 'message' => 'Password disimpan. Silakan login.']);
    }

    public function me(Request $r): JsonResponse
    {
        $a = $r->attributes->get('auth');
        return response()->json(['id' => $a->id, 'role' => $a->role, 'name' => $a->name]);
    }

    public function logout(Request $r): JsonResponse
    {
        $a = $r->attributes->get('auth');
        DB::update("update sessions set revoked_at = now(), revoked_reason = 'logout' where token_hash = decode(?, 'hex')", [$a->token_hash]);
        return response()->json(['ok' => true])->withCookie(Cookie::forget('sid'));
    }

    public function changePassword(Request $r): JsonResponse
    {
        $a = $r->attributes->get('auth');
        $current = $r->input('current'); $new = $r->input('password');
        $me = Db::as($a->id, fn () => DB::selectOne('select email, full_name from users where id = ?::uuid', [$a->id]));
        $u = $this->lookup($me->email);
        if (!is_string($current) || !Passwords::verify($u->password_hash, $current)) return $this->err('Password saat ini salah.', 400);
        if ($p = Passwords::problem($new, $me->email, $me->full_name)) return $this->err($p, 400);
        if (Passwords::verify($u->password_hash, $new)) return $this->err('Password baru harus berbeda.', 400);
        Db::as($a->id, function () use ($a, $new) {
            DB::update('update users set password_hash = ?, password_changed_at = now() where id = ?::uuid', [Passwords::hash($new), $a->id]);
            DB::update("update sessions set revoked_at = now(), revoked_reason = 'password_changed'
                         where user_id = ?::uuid and token_hash <> decode(?, 'hex') and revoked_at is null", [$a->id, $a->token_hash]);
        });
        return response()->json(['ok' => true]);
    }
}
