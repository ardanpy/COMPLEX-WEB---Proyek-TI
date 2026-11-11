<?php

namespace App\Providers;

use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        if (strlen((string) config('complex.otp_pepper')) < 32) {
            throw new \RuntimeException('OTP_PEPPER wajib diisi (minimal 32 karakter). Buat: openssl rand -hex 32');
        }
        $ip = fn (Request $r) => $r->ip();
        RateLimiter::for('global', fn (Request $r) => Limit::perMinute(120)->by($ip($r)));
        RateLimiter::for('login',  fn (Request $r) => Limit::perMinute(10)->by($ip($r)));
        RateLimiter::for('otp',    fn (Request $r) => Limit::perMinute(5)->by($ip($r)));
        RateLimiter::for('guest-start',  fn (Request $r) => Limit::perMinute(10)->by($ip($r)));
        RateLimiter::for('guest-report', fn (Request $r) => Limit::perMinute(5)->by($ip($r)));
    }
}
