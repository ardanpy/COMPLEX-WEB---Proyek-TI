import nodemailer from 'nodemailer';
import { config } from './config.js';
const transport = config.smtp ? nodemailer.createTransport(config.smtp) : null;
export const outbox = [];   // dipakai saat SMTP belum diatur (dev/tes)
/** Email OTP hanya berisi kode + masa berlaku. JANGAN pernah memasukkan password. */
export async function sendOtpMail(to, code, purpose) {
  const subject = purpose === 'activation' ? 'Kode aktivasi akun COMPLEX' : 'Kode reset password COMPLEX';
  const text = `Kode Anda: ${code}\nBerlaku 10 menit. Jangan bagikan kode ini kepada siapa pun.`;
  if (!transport) { outbox.push({ to, code, purpose }); if (!config.prod) console.log(`[DEV mail] ${to}: ${code}`); return; }
  await transport.sendMail({ from: config.mailFrom, to, subject, text });
}
