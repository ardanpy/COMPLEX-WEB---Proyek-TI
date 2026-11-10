import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import sharp from 'sharp';
import { config } from './config.js';

const ALLOWED = new Set(['jpeg', 'png', 'webp']);
export class UploadError extends Error {}

/** Cek isi berkas sebenarnya (bukan nama/MIME dari klien), batasi ukuran & dimensi,
 *  putar sesuai EXIF lalu RE-ENCODE ke JPEG (membuang EXIF/GPS & payload tersembunyi). */
export async function sanitizeImage(buf) {
  if (!buf || buf.length === 0) throw new UploadError('Foto wajib diunggah.');
  if (buf.length > config.maxUploadBytes) throw new UploadError('Ukuran foto maksimal 5 MB.');
  let meta;
  try { meta = await sharp(buf, { limitInputPixels: 40_000_000 }).metadata(); }
  catch { throw new UploadError('Berkas bukan gambar yang valid.'); }
  if (!ALLOWED.has(meta.format)) throw new UploadError('Format foto harus JPEG, PNG, atau WebP.');
  if (!meta.width || !meta.height || meta.width < 100 || meta.height < 100) throw new UploadError('Foto terlalu kecil.');
  return sharp(buf, { limitInputPixels: 40_000_000 })
    .rotate().resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 82 }).toBuffer();             // tanpa withMetadata() => EXIF/GPS dibuang
}

export const newKey = () => `${crypto.randomUUID()}.jpg`;
const KEY_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/;
export async function saveImage(subdir, key, buf) {
  if (!KEY_RE.test(key)) throw new Error('kunci tidak valid');
  const dir = path.resolve(config.uploadDir, subdir);
  await fs.mkdir(dir, { recursive: true, mode: 0o750 });
  await fs.writeFile(path.join(dir, key), buf, { mode: 0o640, flag: 'wx' });
}
export async function readImage(subdir, key) {
  if (!KEY_RE.test(key)) return null;
  try { return await fs.readFile(path.resolve(config.uploadDir, subdir, key)); } catch { return null; }
}
export async function removeImage(subdir, key) { try { await fs.unlink(path.resolve(config.uploadDir, subdir, key)); } catch {} }
