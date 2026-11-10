import { sha256, randomToken } from './crypto.js';
import { tx, txAs } from './db.js';
import { config } from './config.js';

export const SID = 'sid', GSID = 'guest_sid';
export const cookieOpts = (maxAgeSec) => ({
  httpOnly: true, secure: config.cookieSecure, sameSite: 'strict', path: '/', ...(maxAgeSec ? { maxAge: maxAgeSec } : {}),
});

/** Buat sesi server-side. Cookie = token acak (DB hanya menyimpan SHA-256). Mengembalikan token & csrf. */
export async function createSession(c, userId, { remember, ip, ua }) {
  const token = randomToken(32), csrf = randomToken(24);
  const ttl = remember ? 30 * 24 * 3600 : 8 * 3600;
  await c.query(
    `INSERT INTO sessions (user_id, token_hash, csrf_hash, remember, ip, user_agent, expires_at)
     VALUES ($1, $2, $3, $4, $5::inet, left($6, 255), now() + make_interval(secs => $7))`,
    [userId, sha256(token), sha256(csrf), !!remember, ip || null, ua || null, ttl]);
  return { token, csrf, ttl };
}

/** preHandler: wajib login. Role SELALU dibaca dari DB (fn_session_user), bukan dari cookie. */
export function requireAuth(roles) {
  return async function (req, reply) {
    const tok = req.cookies?.[SID];
    if (!tok) return reply.code(401).send({ error: 'Silakan login.' });
    const th = sha256(tok);
    const row = await tx(async (c) => {
      const u = (await c.query('SELECT * FROM fn_session_user($1)', [th])).rows[0];
      if (!u) return null;
      const s = (await c.query('SELECT csrf_hash FROM sessions WHERE token_hash = $1', [th])).rows[0];
      return { ...u, csrf_hash: s?.csrf_hash };
    });
    if (!row) { reply.clearCookie(SID, cookieOpts()); return reply.code(401).send({ error: 'Sesi berakhir. Silakan login lagi.' }); }
    if (roles && !roles.includes(row.role)) return reply.code(403).send({ error: 'Tidak punya akses.' });
    if (!['GET', 'HEAD', 'OPTIONS'].includes(req.method)) {
      const given = req.headers['x-csrf-token'];
      if (!given || !row.csrf_hash || !sha256(String(given)).equals(row.csrf_hash)) return reply.code(403).send({ error: 'Token CSRF tidak valid.' });
    }
    req.user = { id: row.user_id, role: row.role, name: row.full_name, unitId: row.unit_id };
    req.sessionHash = th;
  };
}
export const q = (req, fn) => txAs(req.user.id, fn);
