import { requireAuth, q } from '../session.js';
import { sanitizeImage, newKey, saveImage, removeImage, readImage, UploadError } from '../uploads.js';
import { uuidRe } from '../crypto.js';

const clampInt = (v, d, min, max) => { const n = parseInt(v, 10); return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : d; };

/** Ambil bagian multipart: satu berkas "photo" + field teks (note). */
async function readForm(req) {
  let photo = null; const fields = {};
  for await (const part of req.parts({ limits: { files: 1, fileSize: 5 * 1024 * 1024, fields: 3, fieldSize: 1000 } })) {
    if (part.type === 'file') {
      if (part.fieldname !== 'photo') { part.file.resume(); continue; }
      photo = await part.toBuffer();
      if (part.file.truncated) throw new UploadError('Ukuran foto maksimal 5 MB.');
    } else fields[part.fieldname] = part.value;
  }
  return { photo, note: typeof fields.note === 'string' ? fields.note.trim().slice(0, 300) || null : null };
}

export default async function securityRoutes(app) {
  const guard = { preHandler: requireAuth(['security']) };

  // ---------- Absen ----------
  app.get('/security/attendance/status', guard, async (req) => q(req, async (c) => {
    const r = (await c.query('SELECT id, check_in_at FROM security_attendance WHERE user_id = $1 AND check_out_at IS NULL', [req.user.id])).rows[0];
    return { on_duty: !!r, since: r?.check_in_at ?? null, server_time: new Date().toISOString() };
  }));

  app.post('/security/attendance/check-in', guard, async (req, reply) => {
    let form; try { form = await readForm(req); } catch (e) { return fail(reply, e); }
    let jpg; try { jpg = await sanitizeImage(form.photo); } catch (e) { return fail(reply, e); }
    const key = newKey(); await saveImage('attendance', key, jpg);
    try {
      // check_in_at TIDAK dikirim: diisi jam server oleh trigger.
      const row = await q(req, async (c) => (await c.query(
        `INSERT INTO security_attendance (user_id, check_in_photo_key, note) VALUES ($1, $2, $3) RETURNING id, check_in_at`,
        [req.user.id, key, form.note])).rows[0]);
      return reply.code(201).send({ ok: true, id: row.id, check_in_at: row.check_in_at });
    } catch (e) {
      await removeImage('attendance', key);
      if (e.code === '23505') return reply.code(409).send({ error: 'Anda sudah absen masuk dan belum absen pulang.' });
      throw e;
    }
  });

  app.post('/security/attendance/check-out', guard, async (req, reply) => {
    let form; try { form = await readForm(req); } catch (e) { return fail(reply, e); }
    let jpg; try { jpg = await sanitizeImage(form.photo); } catch (e) { return fail(reply, e); }
    const key = newKey(); await saveImage('attendance', key, jpg);
    try {
      const row = await q(req, async (c) => (await c.query(
        `UPDATE security_attendance SET check_out_photo_key = $1, note = coalesce($2, note)
          WHERE user_id = $3 AND check_out_at IS NULL RETURNING id, check_in_at, check_out_at`,
        [key, form.note, req.user.id])).rows[0]);
      if (!row) { await removeImage('attendance', key); return reply.code(409).send({ error: 'Belum ada absen masuk yang terbuka.' }); }
      return { ok: true, id: row.id, check_in_at: row.check_in_at, check_out_at: row.check_out_at };
    } catch (e) { await removeImage('attendance', key); throw e; }
  });

  app.get('/security/attendance', guard, async (req) => {
    const limit = clampInt(req.query.limit, 30, 1, 100), offset = clampInt(req.query.offset, 0, 0, 100000);
    return q(req, async (c) => ({ items: (await c.query(
      `SELECT id, check_in_at, check_in_photo_key, check_out_at, check_out_photo_key, note, on_duty, duration_minutes
         FROM v_security_attendance WHERE user_id = $1 ORDER BY check_in_at DESC LIMIT $2 OFFSET $3`, [req.user.id, limit, offset])).rows }));
  });

  // ---------- Laporan masalah warga (hanya baca) ----------
  const STATUSES = ['dikirim', 'diproses', 'selesai', 'ditolak'], CATS = ['kebersihan', 'fasilitas', 'keamanan', 'lainnya'];
  app.get('/security/reports', { preHandler: requireAuth(['security', 'admin']) }, async (req, reply) => {
    const { status, category } = req.query;
    if (status && !STATUSES.includes(status)) return reply.code(400).send({ error: 'Status tidak valid.' });
    if (category && !CATS.includes(category)) return reply.code(400).send({ error: 'Kategori tidak valid.' });
    const limit = clampInt(req.query.limit, 20, 1, 100), offset = clampInt(req.query.offset, 0, 0, 100000);
    return q(req, async (c) => ({ items: (await c.query(
      `SELECT v.id, v.category, v.title, v.description, v.location_text, b.name AS block, v.incident_date, v.status, v.reporter_name, v.created_at
         FROM v_reports_for_security v LEFT JOIN blocks b ON b.id = v.block_id
        WHERE ($1::report_status IS NULL OR v.status = $1) AND ($2::report_category IS NULL OR v.category = $2)
        ORDER BY v.created_at DESC LIMIT $3 OFFSET $4`, [status ?? null, category ?? null, limit, offset])).rows }));
  });

  app.get('/security/reports/:id', { preHandler: requireAuth(['security', 'admin']) }, async (req, reply) => {
    if (!uuidRe.test(req.params.id)) return reply.code(400).send({ error: 'ID tidak valid.' });
    const row = await q(req, async (c) => (await c.query(
      `SELECT v.id, v.category, v.title, v.description, v.location_text, b.name AS block, v.incident_date, v.status, v.reporter_name, v.created_at, v.updated_at
         FROM v_reports_for_security v LEFT JOIN blocks b ON b.id = v.block_id WHERE v.id = $1`, [req.params.id])).rows[0]);
    return row ?? reply.code(404).send({ error: 'Laporan tidak ditemukan.' });
  });

  // ---------- Tamu aktif (cek di gerbang, hanya baca) ----------
  app.get('/security/guests', guard, async (req) => q(req, async (c) => ({ items: (await c.query(
    `SELECT g.id, g.visitor_name, g.visitor_address, g.vehicle_plate, b.name AS host_block, g.host_house, g.host_name, g.purpose, g.visit_start, g.valid_until
       FROM guest_visits g JOIN blocks b ON b.id = g.host_block_id
      WHERE g.status = 'aktif' AND g.valid_until > now() ORDER BY g.created_at DESC LIMIT 100`)).rows })));

  // ---------- Berkas foto absen: hanya pemilik atau admin (disaring RLS lewat view) ----------
  app.get('/files/attendance/:key', { preHandler: requireAuth(['security', 'admin']) }, async (req, reply) => {
    const key = req.params.key;
    const ok = await q(req, async (c) => (await c.query(
      'SELECT 1 FROM v_security_attendance WHERE check_in_photo_key = $1 OR check_out_photo_key = $1', [key])).rowCount > 0);
    const buf = ok ? await readImage('attendance', key) : null;
    if (!buf) return reply.code(404).send({ error: 'Tidak ditemukan.' });
    return reply.header('Content-Type', 'image/jpeg').header('Cache-Control', 'private, max-age=300').header('X-Content-Type-Options', 'nosniff').send(buf);
  });
}
function fail(reply, e) {
  if (e instanceof UploadError) return reply.code(400).send({ error: e.message });
  if (e?.code === 'FST_REQ_FILE_TOO_LARGE') return reply.code(413).send({ error: 'Ukuran foto maksimal 5 MB.' });
  throw e;
}
