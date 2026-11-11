<?php

namespace App\Support;

use Illuminate\Support\Facades\DB;

/**
 * Semua akses data lewat sini. Koneksi memakai role complex_app (bukan pemilik/superuser).
 * Query WAJIB terparameter (tanda ?), tanpa menyambung string dari input pengguna.
 */
final class Db
{
    /** Transaksi tanpa pengguna (pra-login / jalur tamu). */
    public static function tx(callable $fn): mixed
    {
        return DB::transaction($fn);
    }

    /** Transaksi atas nama pengguna: app.user_id berlaku lokal-transaksi, sehingga RLS bekerja. */
    public static function as(string $userId, callable $fn): mixed
    {
        return DB::transaction(function () use ($userId, $fn) {
            DB::select("select set_config('app.user_id', ?, true)", [$userId]);
            return $fn();
        });
    }
}
