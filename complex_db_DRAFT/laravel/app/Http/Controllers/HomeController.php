<?php

namespace App\Http\Controllers;

use App\Support\Db;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class HomeController extends Controller
{
    /** Beranda sesuai role (role dari DB). Nama fungsi dari whitelist, bukan input. */
    public function index(Request $r)
    {
        $a = $r->attributes->get('auth');
        $fn = $a->role === 'security' ? 'fn_home_security' : 'fn_home';
        $json = Db::as($a->id, fn () => DB::selectOne("select $fn() as h")->h);
        if ($json === null) return response()->json(['error' => 'Akun tidak aktif.'], 403);
        return response($json, 200, ['Content-Type' => 'application/json']);   // jsonb sudah berupa teks JSON
    }
}
