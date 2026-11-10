const env = process.env;
const need = (k) => { if (!env[k]) throw new Error(`Env ${k} wajib diisi`); return env[k]; };
const prod = env.NODE_ENV === 'production';
export const config = {
  prod,
  port: Number(env.PORT || 3000),
  databaseUrl: need('DATABASE_URL'),
  otpPepper: (() => { const p = need('OTP_PEPPER'); if (p.length < 32) throw new Error('OTP_PEPPER minimal 32 karakter'); return Buffer.from(p); })(),
  allowedOrigin: env.ALLOWED_ORIGIN || '',
  trustProxy: env.TRUST_PROXY === 'true',
  cookieSecure: env.COOKIE_SECURE ? env.COOKIE_SECURE === 'true' : prod,
  uploadDir: env.UPLOAD_DIR || './uploads',
  maxUploadBytes: 5 * 1024 * 1024,
  smtp: env.SMTP_HOST ? { host: env.SMTP_HOST, port: Number(env.SMTP_PORT || 587), auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS } : undefined } : null,
  mailFrom: env.MAIL_FROM || 'COMPLEX <noreply@complex.local>',
};
