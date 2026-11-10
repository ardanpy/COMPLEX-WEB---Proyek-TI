import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import multipart from '@fastify/multipart';
import { config } from './config.js';
import authRoutes from './routes/auth.js';
import homeRoutes from './routes/home.js';
import guestRoutes from './routes/guest.js';
import securityRoutes from './routes/security.js';
import adminRoutes from './routes/admin.js';

export async function buildApp(opts = {}) {
  const app = Fastify({ logger: opts.logger ?? true, trustProxy: config.trustProxy, bodyLimit: 64 * 1024 });
  await app.register(helmet, { contentSecurityPolicy: false });   // API JSON; CSP dipasang di server frontend
  await app.register(cookie);
  await app.register(rateLimit, { global: true, max: 120, timeWindow: '1 minute' });
  await app.register(multipart);

  // Pertahanan CSRF lapis 2: request pengubah data wajib berasal dari origin frontend yang diizinkan.
  app.addHook('onRequest', async (req, reply) => {
    if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return;
    const origin = req.headers.origin;
    if (config.allowedOrigin && origin !== config.allowedOrigin) return reply.code(403).send({ error: 'Origin tidak diizinkan.' });
  });
  app.addHook('onSend', async (req, reply) => { reply.header('Cache-Control', reply.getHeader('Cache-Control') ?? 'no-store'); });

  app.setErrorHandler((err, req, reply) => {
    if (err.statusCode && err.statusCode < 500) return reply.code(err.statusCode).send({ error: err.message });
    req.log.error(err);
    reply.code(500).send({ error: 'Terjadi kesalahan pada server.' });   // jangan bocorkan detail SQL
  });

  app.get('/health', async () => ({ ok: true }));
  await app.register(authRoutes); await app.register(homeRoutes); await app.register(guestRoutes);
  await app.register(securityRoutes); await app.register(adminRoutes);
  return app;
}
