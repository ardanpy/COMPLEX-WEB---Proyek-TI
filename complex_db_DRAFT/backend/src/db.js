import pg from 'pg';
import { config } from './config.js';
export const pool = new pg.Pool({ connectionString: config.databaseUrl, max: 10, idleTimeoutMillis: 30000 });

/** Transaksi TANPA pengguna (pra-login / jalur tamu). Semua query WAJIB terparameter. */
export async function tx(fn) { return run(null, fn); }
/** Transaksi atas nama pengguna: set app.user_id (lokal transaksi) agar RLS bekerja. */
export async function txAs(userId, fn) { return run(userId, fn); }

async function run(userId, fn) {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    if (userId) await c.query("SELECT set_config('app.user_id', $1, true)", [userId]);
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) { try { await c.query('ROLLBACK'); } catch {} throw e; }
  finally { c.release(); }
}
