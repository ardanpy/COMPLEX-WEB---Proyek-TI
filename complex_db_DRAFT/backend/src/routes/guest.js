import { tx } from '../db.js';
import { sha256, randomToken, uuidRe } from '../crypto.js';
import { GSID, cookieOpts } from '../session.js';

const clean = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const MSG = { limit: 'Terlalu banyak percobaan. Coba lagi nanti.', no_session: 'Sesi tamu berakhir. Mulai lagi dari halaman login.',
  active_exists: 'Anda masih memiliki laporan tamu yang aktif.', invalid: 'Data tidak valid.', not_found: 'Laporan tidak ditemukan.' };
const guestHash = (req) => (req.cookies?.[GSID] ? sha256(req.cookies[GSID]) : null);

export default async function guestRoutes(app) {
  // Tombol "Masuk sebagai tamu" di halaman login. Tamu bukan akun: hanya sesi anonim 24 jam.
  app.post('/guest/start', { config: { rateLimit: { max: 10, timeWindow: '1 minute' } } }, async (req, reply) => {
    const token = randomToken(32);
    const st = await tx(async (c) => (await c.query('SELECT fn_guest_session_start($1, $2::inet, $3) AS st',
      [sha256(token), req.ip, req.headers['user-agent'] ?? null])).rows[0].st);
    if (st !== 'ok') return reply.code(st === 'limit' ? 429 : 400).send({ error: MSG[st] });
    reply.setCookie(GSID, token, cookieOpts(24 * 3600));
    return { ok: true };
  });

  app.get('/guest/home', async (req, reply) => {
    const h = guestHash(req);
    const data = h && await tx(async (c) => (await c.query('SELECT fn_guest_home($1) AS h', [h])).rows[0].h);
    if (!data) return reply.code(401).send({ error: MSG.no_session });
    return data;
  });

  app.post('/guest/report', { config: { rateLimit: { max: 5, timeWindow: '1 minute' } } }, async (req, reply) => {
    const h = guestHash(req); const b = req.body ?? {};
    if (!h) return reply.code(401).send({ error: MSG.no_session });
    const blockId = Number(b.block_id);
    const name = clean(b.name, 100), address = clean(b.address, 200), purpose = clean(b.purpose, 300);
    if (!name || !address || !purpose || !Number.isInteger(blockId) || !clean(b.house, 10)) return reply.code(400).send({ error: 'Lengkapi nama, alamat, blok/rumah tujuan, dan keperluan.' });
    let start = null; if (b.visit_start) { const d = new Date(b.visit_start); if (!isNaN(d)) start = d.toISOString(); }
    const row = await tx(async (c) => (await c.query(
      'SELECT * FROM fn_guest_report_create($1,$2,$3,$4::smallint,$5,$6,$7,$8,$9,$10::timestamptz,$11::inet)',
      [h, name, address, blockId, clean(b.house, 10), clean(b.host_name, 100), purpose, clean(b.phone, 15).replace(/\D/g, ''), clean(b.plate, 12), start, req.ip])).rows[0]);
    if (row.result !== 'ok') return reply.code(row.result === 'limit' ? 429 : row.result === 'no_session' ? 401 : 400).send({ error: MSG[row.result] ?? MSG.invalid });
    return { ok: true, id: row.visit_id };
  });

  app.post('/guest/report/:id/end', async (req, reply) => {
    const h = guestHash(req); const status = req.body?.status;
    if (!h) return reply.code(401).send({ error: MSG.no_session });
    if (!uuidRe.test(req.params.id) || !['selesai', 'dibatalkan'].includes(status)) return reply.code(400).send({ error: MSG.invalid });
    const st = await tx(async (c) => (await c.query('SELECT fn_guest_report_end($1,$2,$3::visit_status) AS st', [h, req.params.id, status])).rows[0].st);
    if (st !== 'ok') return reply.code(st === 'not_found' ? 404 : 400).send({ error: MSG[st] ?? MSG.invalid });
    return { ok: true };
  });
}
