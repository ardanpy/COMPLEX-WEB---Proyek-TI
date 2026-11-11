<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;

/** Lapis CSRF ke-2: request pengubah data harus dari origin frontend yang diizinkan. */
class OriginCheck
{
    public function handle(Request $request, Closure $next)
    {
        if (!in_array($request->method(), ['GET', 'HEAD', 'OPTIONS'], true)) {
            $allowed = config('complex.allowed_origin');
            if ($allowed && $request->headers->get('Origin') !== $allowed) {
                return response()->json(['error' => 'Origin tidak diizinkan.'], 403);
            }
        }
        return $next($request);
    }
}
