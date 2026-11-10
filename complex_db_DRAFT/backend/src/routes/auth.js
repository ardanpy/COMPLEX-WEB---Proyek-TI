import { tx, txAs } from '../db.js';
import { sha256, randomToken, otpCode, otpHash } from '../crypto.js';
import { createSession, requireAuth, SID, cookieOpts } from '../session.js';
import { hashPassword, verifyPassword, dummyHash, passwordProblem } from '../password.js';
import { sendOtpMail } from '../mail.js';

const GENERIC_LOGIN = 'Email atau password salah.';
const GENERIC_OTP_REQ = 'Jika email terdaftar, kode telah dikirim.';
const GENERIC_OTP_BAD = 'Kode salah atau kedaluwarsa.';
const PURPOSES = new Set(['activation', 'password_reset']);
const norm = (e) => (typeof e === 'string' ? e.trim().toLowerCase() : '');
const rl = (max, win = '1 minute') => ({ config: { rateLimit: { max, timeWindow: win } } });
const lookup = async (c, email) => (await c.query('SELECT * FROM fn_login_lookup($1)', [email])).rows[0];

async function issueOtp(req, uid, email, purpose) {
  const code = otpCode();
  const st = await tx(async (c) => (await c.query(
    'SELECT fn_otp_issue($1, $2::auth_token_purpose, $3, $4::inet) AS st', [uid, purpose, otpHash(uid, purpose, code), req.ip])).rows[0].st);
  if (st === 'ok') await sendOtpMail(email, code, purpose);
  return st;
}

export default async function authRoutes(app) {
  app.post('/auth/login', rl(10), async (req, reply) => {
    const email = norm(req.body?.email), password = req.body?.password, remember = !!req.body?.remember;
    if (!email || typeof password !== 'string' || password.length > 200) return reply.code(400).send({ error: GENERIC_LOGIN });
    const ua = req.headers['user-agent'];
    const r = await tx((c) => lookup(c, email));
    if (!r) {                                     // samakan waktu respons dgn akun yang ada
      await verifyPassword(await dummyHash(), password);
      await tx((c) => c.query("SELECT fn_login_failed(NULL, $1, $2::inet, $3)", [email, req.ip, ua]));
      return reply.code(401).send({ error: GENERIC_LOGIN });
    }
    const ok = await verifyPassword(r.password_hash, password);
    if (!ok || r.status !== 'aktif' || r.is_locked) {
      await tx((c) => c.query('SELECT fn_login_failed($1, $2, $3::inet, $4)', [r.id, email, req.ip, ua]));
      return reply.code(401).send({ error: GENERIC_LOGIN });
    }
    if (!r.activated_at) {                        // login pertama: wajib OTP, belum ada sesi
      if (!r.activation_valid) return reply.code(401).send({ error: GENERIC_LOGIN });
      await issueOtp(req, r.id, email, 'activation');
      return { next: 'otp', purpose: 'activation', message: 'Kode verifikasi dikirim ke email Anda.' };
    }
    const s = await tx(async (c) => {
      await c.query('SELECT fn_login_succeeded($1, $2, $3::inet, $4)', [r.id, email, req.ip, ua]);
      return createSession(c, r.id, { remember, ip: req.ip, ua });
    });
    reply.setCookie(SID, s.token, cookieOpts(s.ttl));
    return { ok: true, csrf: s.csrf, role: r.role };
  });

  app.post('/auth/otp/resend', rl(5), async (req) => {       // aktivasi: butuh email + password sementara lagi
    const email = norm(req.body?.email), purpose = req.body?.purpose;
    if (purpose === 'password_reset') {
      const r = email && await tx((c) => lookup(c, email));
      if (r) await issueOtp(req, r.id, email, 'password_reset');
    } else if (purpose === 'activation') {
      const r = email && await tx((c) => lookup(c, email));
      if (r && !r.activated_at && r.activation_valid && await verifyPassword(r.password_hash, String(req.body?.password ?? ''))) await issueOtp(req, r.id, email, 'activation');
      else await verifyPassword(await dummyHash(), 'x');
    }
    return { message: GENERIC_OTP_REQ };
  });

  app.post('/auth/forgot', rl(5), async (req) => {
    const email = norm(req.body?.email);
    const r = email && await tx((c) => lookup(c, email));
    if (r && r.activated_at && r.status === 'aktif') await issueOtp(req, r.id, email, 'password_reset');
    else await verifyPassword(await dummyHash(), 'x');
    return { message: GENERIC_OTP_REQ };           // identik apa pun hasilnya
  });

  app.post('/auth/otp/verify', rl(10), async (req, reply) => {
    const email = norm(req.body?.email), purpose = req.body?.purpose, code = String(req.body?.code ?? '');
    if (!PURPOSES.has(purpose) || !/^[0-9]{6}$/.test(code)) return reply.code(400).send({ error: GENERIC_OTP_BAD });
    const r = email && await tx((c) => lookup(c, email));
    if (!r) return reply.code(400).send({ error: GENERIC_OTP_BAD });
    const ticket = randomToken(32);
    const st = await tx(async (c) => (await c.query(
      'SELECT fn_otp_verify($1, $2::auth_token_purpose, $3, $4, $5::inet) AS st',
      [r.id, purpose, otpHash(r.id, purpose, code), sha256(ticket), req.ip])).rows[0].st);
    if (st !== 'ok') return reply.code(400).send({ error: GENERIC_OTP_BAD });   // satu pesan untuk semua kegagalan
    return { ticket };
  });

  app.post('/auth/set-password', rl(10), async (req, reply) => {
    const { ticket, password } = req.body ?? {};
    if (typeof ticket !== 'string' || ticket.length < 20) return reply.code(400).send({ error: 'Tiket tidak valid.' });
    const problem = passwordProblem(password);
    if (problem) return reply.code(400).send({ error: problem });
    const uid = await tx(async (c) => (await c.query('SELECT fn_set_password($1, $2, $3::inet) AS id',
      [sha256(ticket), await hashPassword(password), req.ip])).rows[0].id);
    if (!uid) return reply.code(400).send({ error: 'Tiket tidak valid atau kedaluwarsa.' });
    return { ok: true, message: 'Password disimpan. Silakan login.' };
  });

  app.get('/auth/me', { preHandler: requireAuth() }, async (req) => ({ id: req.user.id, role: req.user.role, name: req.user.name }));

  app.post('/auth/logout', { preHandler: requireAuth() }, async (req, reply) => {
    await tx((c) => c.query("UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE token_hash = $1", [req.sessionHash]));
    reply.clearCookie(SID, cookieOpts());
    return { ok: true };
  });

  app.post('/auth/change-password', { preHandler: requireAuth(), ...rl(5) }, async (req, reply) => {
    const { current, password } = req.body ?? {};
    const me = await txAs(req.user.id, async (c) => (await c.query('SELECT email, full_name FROM users WHERE id = $1', [req.user.id])).rows[0]);
    const r = await tx((c) => lookup(c, me.email));
    if (typeof current !== 'string' || !(await verifyPassword(r.password_hash, current))) return reply.code(400).send({ error: 'Password saat ini salah.' });
    const problem = passwordProblem(password, { email: me.email, name: me.full_name });
    if (problem) return reply.code(400).send({ error: problem });
    if (await verifyPassword(r.password_hash, password)) return reply.code(400).send({ error: 'Password baru harus berbeda.' });
    await txAs(req.user.id, async (c) => {
      await c.query('UPDATE users SET password_hash = $1, password_changed_at = now() WHERE id = $2', [await hashPassword(password), req.user.id]);
      await c.query("UPDATE sessions SET revoked_at = now(), revoked_reason = 'password_changed' WHERE user_id = $1 AND token_hash <> $2 AND revoked_at IS NULL", [req.user.id, req.sessionHash]);
    });
    return { ok: true };
  });
}
