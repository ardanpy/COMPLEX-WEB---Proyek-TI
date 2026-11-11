<?php

namespace App\Support;

/** Token & hash. bytea dikirim sebagai hex dan di-decode di SQL: decode(?, 'hex'). */
final class Tok
{
    public static function sha256Hex(string $s): string { return hash('sha256', $s); }

    public static function random(int $bytes = 32): string
    {
        return rtrim(strtr(base64_encode(random_bytes($bytes)), '+/', '-_'), '=');
    }

    public static function otpCode(): string { return str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT); }

    /** Sama dengan tests/login_sim.py: HMAC-SHA256(pepper, "<uid>:<purpose>:<code>"). */
    public static function otpHashHex(string $uid, string $purpose, string $code): string
    {
        return hash_hmac('sha256', "$uid:$purpose:$code", (string) config('complex.otp_pepper'));
    }

    public static function isUuid(string $s): bool
    {
        return (bool) preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $s);
    }
}
