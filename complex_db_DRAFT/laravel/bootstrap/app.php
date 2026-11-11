<?php

use App\Http\Middleware\OriginCheck;
use App\Http\Middleware\SessionAuth;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        api: __DIR__.'/../routes/api.php',
        apiPrefix: '',                      // endpoint tanpa awalan /api (lihat docs/API.md)
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware) {
        $middleware->alias(['session.auth' => SessionAuth::class]);
        $middleware->api(prepend: [OriginCheck::class], append: ['throttle:global']);
        // Di belakang reverse proxy: set TRUSTED_PROXIES di .env agar $request->ip() benar.
        $middleware->trustProxies(at: env('TRUSTED_PROXIES') ?: null);
    })
    ->withExceptions(function (Exceptions $exceptions) {
        $exceptions->shouldRenderJsonWhen(fn () => true);   // API: selalu JSON; galat 500 tidak membocorkan detail SQL
    })->create();
