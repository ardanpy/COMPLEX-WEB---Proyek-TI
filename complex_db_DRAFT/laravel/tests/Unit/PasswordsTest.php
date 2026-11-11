<?php

namespace Tests\Unit;

use App\Support\Passwords;
use App\Support\Tok;
use PHPUnit\Framework\TestCase;

/** Tes murni PHP (tanpa DB). Jalankan: php artisan test --testsuite=Unit */
class PasswordsTest extends TestCase
{
    public function test_hash_memakai_argon2id_dan_terverifikasi(): void
    {
        $h = Passwords::hash('Kuda-Hijau-Melompat-92');
        $this->assertStringStartsWith('$argon2id$', $h);
        $this->assertTrue(Passwords::verify($h, 'Kuda-Hijau-Melompat-92'));
        $this->assertFalse(Passwords::verify($h, 'salah'));
    }

    public function test_kebijakan_password(): void
    {
        $this->assertNotNull(Passwords::problem('pendek'));
        $this->assertNotNull(Passwords::problem('budi-santoso-123', 'budisantoso@x.id', 'Budi Santoso'));
        $this->assertNull(Passwords::problem('Kuda-Hijau-Melompat-92'));
    }

    public function test_uuid_dan_kode_otp(): void
    {
        $this->assertTrue(Tok::isUuid('00000000-0000-0000-0000-0000000000e1'));
        $this->assertFalse(Tok::isUuid("x'; drop table users;--"));
        $this->assertMatchesRegularExpression('/^[0-9]{6}$/', Tok::otpCode());
    }
}
