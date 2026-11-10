import argon2 from 'argon2';
const OPTS = { type: argon2.argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 };
export const hashPassword = (pw) => argon2.hash(pw, OPTS);
export const verifyPassword = (hash, pw) => argon2.verify(hash, pw).catch(() => false);
let dummy; export const dummyHash = async () => (dummy ??= await hashPassword('dummy-untuk-menyamakan-waktu'));
/** Kebijakan: >= 12 karakter, bukan email/nama. Mengembalikan pesan galat atau null. */
export function passwordProblem(pw, { email = '', name = '' } = {}) {
  if (typeof pw !== 'string' || pw.length < 12) return 'Password minimal 12 karakter.';
  if (pw.length > 128) return 'Password terlalu panjang.';
  const low = pw.toLowerCase();
  if (email && low.includes(email.split('@')[0].toLowerCase()) && email.split('@')[0].length >= 4) return 'Password tidak boleh memuat bagian email.';
  if (name && name.split(/\s+/).some((p) => p.length >= 4 && low.includes(p.toLowerCase()))) return 'Password tidak boleh memuat nama Anda.';
  return null;
}
export const tempPassword = () => {
  const a = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  let s = ''; for (const b of crypto.getRandomValues(new Uint8Array(14))) s += a[b % a.length];
  return s + '#7';
};
