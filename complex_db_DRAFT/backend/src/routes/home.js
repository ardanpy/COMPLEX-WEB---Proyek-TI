import { requireAuth, q } from '../session.js';
export default async function homeRoutes(app) {
  // Setelah login: beranda sesuai role (role dari DB). Security memakai fn_home_security(), bukan fn_home().
  app.get('/home', { preHandler: requireAuth() }, async (req, reply) => {
    const fn = req.user.role === 'security' ? 'fn_home_security' : 'fn_home';
    const data = await q(req, async (c) => (await c.query(`SELECT ${fn}() AS h`)).rows[0].h);   // nama fungsi dari whitelist di atas, bukan input
    if (!data) return reply.code(403).send({ error: 'Akun tidak aktif.' });
    return data;
  });
}
