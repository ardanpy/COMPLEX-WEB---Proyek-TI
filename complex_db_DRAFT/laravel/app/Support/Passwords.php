<?php

namespace App\Support;

final class Passwords
{
    /** Parameter sama dengan yang diharapkan DB: hash berawalan $argon2id$ (CHECK pada kolom password_hash). */
    public static function hash(string $pw): string
    {
        return password_hash($pw, PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1]);
    }

    public static function verify(string $hash, string $pw): bool { return password_verify($pw, $hash); }

    private static ?string $dummy = null;
    /** Dipakai agar waktu respons login email tak dikenal sama dengan email terdaftar. */
    public static function burn(string $pw): void
    {
        self::$dummy ??= self::hash('dummy-untuk-menyamakan-waktu');
        password_verify($pw, self::$dummy);
    }

    /** Null bila lolos; selain itu pesan galat. */
    public static function problem(mixed $pw, string $email = '', string $name = ''): ?string
    {
        if (!is_string($pw) || mb_strlen($pw) < 12) return 'Password minimal 12 karakter.';
        if (mb_strlen($pw) > 128) return 'Password terlalu panjang.';
        $low = mb_strtolower($pw);
        $local = $email !== '' ? mb_strtolower(explode('@', $email)[0]) : '';
        if (mb_strlen($local) >= 4 && str_contains($low, $local)) return 'Password tidak boleh memuat bagian email.';
        foreach (preg_split('/\s+/', trim($name)) ?: [] as $part) {
            if (mb_strlen($part) >= 4 && str_contains($low, mb_strtolower($part))) return 'Password tidak boleh memuat nama Anda.';
        }
        return null;
    }

    public static function temp(): string
    {
        $a = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
        $s = '';
        for ($i = 0; $i < 14; $i++) $s .= $a[random_int(0, strlen($a) - 1)];
        return $s.'#7';
    }
}
