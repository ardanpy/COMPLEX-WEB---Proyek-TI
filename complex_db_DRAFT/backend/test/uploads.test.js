// Tes unit pemrosesan foto (tanpa DB). Jalankan: DATABASE_URL=x OTP_PEPPER=$(openssl rand -hex 32) node --test test/
import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import { sanitizeImage, UploadError } from '../src/uploads.js';
import { passwordProblem } from '../src/password.js';
import { otpHash, sha256 } from '../src/crypto.js';

const img = (fmt, w = 400, h = 300) => sharp({ create: { width: w, height: h, channels: 3, background: '#4a7' } })[fmt]().toBuffer();

test('JPEG/PNG/WebP valid diterima dan di-encode ulang ke JPEG', async () => {
  for (const f of ['jpeg', 'png', 'webp']) {
    const out = await sanitizeImage(await img(f));
    assert.equal((await sharp(out).metadata()).format, 'jpeg');
  }
});
test('EXIF/GPS dibuang', async () => {
  const withExif = await sharp({ create: { width: 300, height: 300, channels: 3, background: '#fff' } })
    .jpeg().withExif({ IFD0: { Copyright: 'rahasia-lokasi' } }).toBuffer();
  assert.ok((await sharp(withExif).metadata()).exif, 'prasyarat: sumber punya EXIF');
  const out = await sanitizeImage(withExif);
  assert.equal((await sharp(out).metadata()).exif, undefined);
  assert.ok(!out.includes(Buffer.from('rahasia-lokasi')));
});
test('bukan gambar / berkas menyamar ditolak', async () => {
  await assert.rejects(sanitizeImage(Buffer.from('<?php system($_GET[1]); ?>')), UploadError);
  await assert.rejects(sanitizeImage(Buffer.from('GIF89a' + 'x'.repeat(200))), UploadError);
  await assert.rejects(sanitizeImage(Buffer.alloc(0)), UploadError);
});
test('SVG ditolak (format di luar JPEG/PNG/WebP)', async () => {
  await assert.rejects(sanitizeImage(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"><script>alert(1)</script></svg>')), UploadError);
});
test('terlalu besar / terlalu kecil ditolak; gambar besar diperkecil', async () => {
  await assert.rejects(sanitizeImage(Buffer.alloc(5 * 1024 * 1024 + 1)), /5 MB/);
  await assert.rejects(sanitizeImage(await img('jpeg', 40, 40)), /kecil/);
  const big = await sanitizeImage(await img('jpeg', 3000, 2000));
  assert.ok((await sharp(big).metadata()).width <= 1600);
});
test('kebijakan password', () => {
  assert.ok(passwordProblem('pendek'));
  assert.ok(passwordProblem('budi-santoso-123', { email: 'budisantoso@x.id', name: 'Budi Santoso' }));
  assert.equal(passwordProblem('Kuda-Hijau-Melompat-92'), null);
});
test('hash OTP deterministik per (user,tujuan,kode) dan berbeda bila salah satu berubah', () => {
  const a = otpHash('u1', 'activation', '123456');
  assert.ok(a.equals(otpHash('u1', 'activation', '123456')));
  assert.ok(!a.equals(otpHash('u1', 'password_reset', '123456')));
  assert.ok(!a.equals(otpHash('u2', 'activation', '123456')));
  assert.equal(sha256('x').length, 32);
});
