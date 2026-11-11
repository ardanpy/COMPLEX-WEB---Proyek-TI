<?php

namespace App\Support;

use Intervention\Image\Drivers\Gd\Driver;
use Intervention\Image\ImageManager;

/**
 * Periksa ISI berkas (bukan nama/MIME klien), batasi ukuran & dimensi, putar sesuai EXIF, lalu RE-ENCODE ke JPEG:
 * EXIF/GPS dan muatan tersembunyi terbuang. Butuh: composer require intervention/image  + ekstensi php-gd.
 */
final class ImageSanitizer
{
    private const ALLOWED = ['image/jpeg', 'image/png', 'image/webp'];

    public static function clean(?string $bytes): string
    {
        if ($bytes === null || $bytes === '') throw new UploadException('Foto wajib diunggah.');
        if (strlen($bytes) > config('complex.max_upload_kb') * 1024) throw new UploadException('Ukuran foto maksimal 5 MB.');
        $info = @getimagesizefromstring($bytes);
        if ($info === false) throw new UploadException('Berkas bukan gambar yang valid.');
        if (!in_array($info['mime'], self::ALLOWED, true)) throw new UploadException('Format foto harus JPEG, PNG, atau WebP.');
        [$w, $h] = $info;
        if ($w < 100 || $h < 100) throw new UploadException('Foto terlalu kecil.');
        if ($w * $h > 40_000_000) throw new UploadException('Dimensi foto terlalu besar.');
        try {
            $img = (new ImageManager(new Driver()))->read($bytes)->orient()->scaleDown(1600, 1600);
            return (string) $img->toJpeg(82);
        } catch (\Throwable) {
            throw new UploadException('Berkas bukan gambar yang valid.');
        }
    }

    public static function newKey(): string { return (string) \Illuminate\Support\Str::uuid().'.jpg'; }

    public static function validKey(string $key): bool
    {
        return (bool) preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/', $key);
    }
}
