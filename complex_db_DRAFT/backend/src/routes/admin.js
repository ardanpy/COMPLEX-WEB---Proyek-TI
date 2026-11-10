import { requireAuth, q } from '../session.js';
import { hashPassword, tempPassword } from '../password.js';
import { uuidRe } from '../crypto.js';

const clampInt = (v, d, min, max) => { const n = parseInt(v, 10); return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : d; };
const normPhone = (p) => { const d = String(p ?? '').replace(/\D/g, ''); if (!d) return null; return d.startsWith('0') ? '62' + d.slice(1) : d; };

export default async function adminRoutes(app) {
  const guard = { preHandler: requireAuth(['admin']) };

  // Admin mendaftarkan akun warga/security. Password sementara dibuat server, ditampilkan SEKALI ke admin
  // (diberikan lewat jalur lain, bukan email). Akun wajib aktivasi OTP saat login pertama.
  app.post('/admin/users', guard, async (req, reply) => {
    const b = req.body ?? {};
    const role = b.role;
    if (!['warga', 'security'].includes(role)) return reply.code(400).send({ error: 'Role harus warga atau security.' });
    const email = typeof b.email === 'string' ? b.email.trim().toLowerCase() : '';
    const name = typeof b.full_name === 'string' ? b.full_name.trim() : '';
    if (!email || name.length < 2) return reply.code(400).send({ error: 'Email dan nama wajib diisi.' });
    const temp = tempPassword(), hash = await hashPassword(temp);
    try {
      const row = await q(req, async (c) => {
        let unitId = null;
        if (role === 'warga') {
          const u = (await c.query('SELECT id FROM units WHERE block_id = $1 AND house_number = upper($2)', [Number(b.block_id), String(b.house_number ?? '').trim()])).rows[0];
          if (!u) throw Object.assign(new Error('unit'), { code: 'NO_UNIT' });
          unitId = u.id;
        }
        return (await c.query(
          `INSERT INTO users (email, full_name, phone, role, unit_id, password_hash, created_by)
           VALUES ($1, $2, $3, $4::user_role, $5, $6, $7) RETURNING id, email, full_name, role`,
          [email, name, normPhone(b.phone), role, unitId, hash, req.user.id])).rows[0];
      });
      return reply.code(201).send({ user: row, temp_password: temp, note: 'Berikan password sementara lewat jalur lain. Berlaku 7 hari; wajib OTP email saat login pertama.' });
    } catch (e) {
      if (e.code === 'NO_UNIT') return reply.code(400).send({ error: 'Blok/nomor rumah tidak ditemukan.' });
      if (e.code === '23505') return reply.code(409).send({ error: 'Email sudah terdaftar.' });
      if (e.code === '23514') return reply.code(400).send({ error: 'Data tidak memenuhi aturan (cek email/telepon/nama).' });
      throw e;
    }
  });

  app.get('/admin/users', guard, async (req) => {
    const limit = clampInt(req.query.limit, 50, 1, 200), offset = clampInt(req.query.offset, 0, 0, 100000);
    const role = ['admin', 'warga', 'security'].includes(req.query.role) ? req.query.role : null;
    return q(req, async (c) => ({ items: (await c.query(
      `SELECT u.id, u.email, u.full_name, u.phone, u.role, u.status, u.activated_at, u.last_login_at, b.name AS block, un.house_number
         FROM users u LEFT JOIN units un ON un.id = u.unit_id LEFT JOIN blocks b ON b.id = un.block_id
        WHERE ($1::user_role IS NULL OR u.role = $1) ORDER BY u.created_at DESC LIMIT $2 OFFSET $3`, [role, limit, offset])).rows }));
  });

  app.post('/admin/users/:id/reset-password', guard, async (req, reply) => {
    if (!uuidRe.test(req.params.id)) return reply.code(400).send({ error: 'ID tidak valid.' });
    const temp = tempPassword(), hash = await hashPassword(temp);
    try {
      await q(req, (c) => c.query('SELECT fn_admin_reset_password($1, $2)', [req.params.id, hash]));
    } catch (e) {
      if (e.code === '42501') return reply.code(403).send({ error: 'Hanya admin.' });
      if (/tidak ditemukan/i.test(e.message)) return reply.code(404).send({ error: 'Akun tidak ditemukan.' });
      throw e;
    }
    return { temp_password: temp, note: 'Berikan lewat jalur lain (bukan email). Akun kembali ke status belum aktif dan wajib OTP.' };
  });

  app.patch('/admin/users/:id/status', guard, async (req, reply) => {
    const st = req.body?.status;
    if (!uuidRe.test(req.params.id) || !['aktif', 'nonaktif', 'ditangguhkan'].includes(st)) return reply.code(400).send({ error: 'Data tidak valid.' });
    try {
      const n = await q(req, async (c) => (await c.query("UPDATE users SET status = $1::user_status WHERE id = $2 AND role IN ('warga','security')", [st, req.params.id])).rowCount);
      if (!n) return reply.code(404).send({ error: 'Akun tidak ditemukan.' });
      if (st !== 'aktif') await q(req, (c) => c.query("UPDATE sessions SET revoked_at = now(), revoked_reason = 'status_changed' WHERE user_id = $1 AND revoked_at IS NULL", [req.params.id]));
      return { ok: true };
    } catch (e) { if (e.code === '23514' || e.code === 'P0001') return reply.code(400).send({ error: e.message }); throw e; }
  });

  // Rekap absen seluruh security (admin)
  app.get('/admin/attendance', guard, async (req, reply) => {
    const { user_id, from, to } = req.query;
    if (user_id && !uuidRe.test(user_id)) return reply.code(400).send({ error: 'user_id tidak valid.' });
    const okDate = (d) => !d || /^\d{4}-\d{2}-\d{2}$/.test(d);
    if (!okDate(from) || !okDate(to)) return reply.code(400).send({ error: 'Format tanggal YYYY-MM-DD.' });
    const limit = clampInt(req.query.limit, 50, 1, 200), offset = clampInt(req.query.offset, 0, 0, 100000);
    return q(req, async (c) => ({ items: (await c.query(
      `SELECT id, user_id, full_name, check_in_at, check_in_photo_key, check_out_at, check_out_photo_key, note, on_duty, duration_minutes
         FROM v_security_attendance
        WHERE ($1::uuid IS NULL OR user_id = $1) AND ($2::date IS NULL OR check_in_at >= $2::date) AND ($3::date IS NULL OR check_in_at < $3::date + 1)
        ORDER BY check_in_at DESC LIMIT $4 OFFSET $5`, [user_id ?? null, from ?? null, to ?? null, limit, offset])).rows }));
  });
}
