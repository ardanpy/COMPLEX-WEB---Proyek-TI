import { buildApp } from './app.js';
import { config } from './config.js';
import { pool } from './db.js';
const app = await buildApp();
// pembersihan berkala (sesi, OTP, tamu kedaluwarsa)
setInterval(() => pool.query('SELECT fn_purge_expired()').catch((e) => app.log.error(e)), 6 * 3600 * 1000).unref();
await app.listen({ port: config.port, host: '0.0.0.0' });
for (const s of ['SIGINT', 'SIGTERM']) process.on(s, async () => { await app.close(); await pool.end(); process.exit(0); });
