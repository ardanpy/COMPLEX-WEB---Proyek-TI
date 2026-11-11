<?php

namespace App\Http\Middleware;

use App\Support\Tok;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

/**
 * Pengganti guard bawaan Laravel (sengaja tidak memakai session/Auth bawaan):
 * cookie `sid` opaque -> SHA-256 -> fn_session_user() di DB. Role SELALU dari DB, bukan dari cookie/klien.
 * Pemakaian di route: ->middleware('session.auth')  atau  'session.auth:security,admin'
 */
class SessionAuth
{
    public function handle(Request $request, Closure $next, string ...$roles)
    {
        $tok = $request->cookie('sid');
        if (!is_string($tok) || $tok === '') return response()->json(['error' => 'Silakan login.'], 401);
        $th = Tok::sha256Hex($tok);

        $u = DB::selectOne("select * from fn_session_user(decode(?, 'hex'))", [$th]);
        if (!$u) {
            return response()->json(['error' => 'Sesi berakhir. Silakan login lagi.'], 401)->withCookie(\Illuminate\Support\Facades\Cookie::forget('sid'));
        }
        if ($roles && !in_array($u->role, $roles, true)) return response()->json(['error' => 'Tidak punya akses.'], 403);

        if (!in_array($request->method(), ['GET', 'HEAD', 'OPTIONS'], true)) {
            $given = (string) $request->header('X-CSRF-Token', '');
            $ok = $given !== '' && DB::selectOne(
                "select (csrf_hash is not null and csrf_hash = decode(?, 'hex')) as ok from sessions where token_hash = decode(?, 'hex')",
                [Tok::sha256Hex($given), $th]
            )?->ok;
            if (!$ok) return response()->json(['error' => 'Token CSRF tidak valid.'], 403);
        }

        $request->attributes->set('auth', (object) [
            'id' => $u->user_id, 'role' => $u->role, 'name' => $u->full_name, 'unit_id' => $u->unit_id, 'token_hash' => $th,
        ]);
        return $next($request);
    }
}
