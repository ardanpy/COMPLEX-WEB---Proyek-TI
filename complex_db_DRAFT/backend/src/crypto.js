import crypto from 'node:crypto';
import { config } from './config.js';
export const sha256 = (s) => crypto.createHash('sha256').update(s).digest();
export const randomToken = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');
export const otpCode = () => String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
// HMAC dgn pepper: format sama dengan tests/login_sim.py  ->  "<uid>:<purpose>:<code>"
export const otpHash = (uid, purpose, code) =>
  crypto.createHmac('sha256', config.otpPepper).update(`${uid}:${purpose}:${code}`).digest();
export const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
