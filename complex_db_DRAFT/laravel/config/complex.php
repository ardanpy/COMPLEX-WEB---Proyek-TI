<?php

return [
    // Pepper HMAC untuk OTP: HANYA di env backend, tidak pernah di database.
    'otp_pepper'     => env('OTP_PEPPER'),
    'allowed_origin' => env('ALLOWED_ORIGIN'),                       // origin frontend; kosong = tidak diperiksa (hanya dev)
    'cookie_secure'  => (bool) env('COOKIE_SECURE', env('APP_ENV') === 'production'),
    'max_upload_kb'  => 5120,
];
