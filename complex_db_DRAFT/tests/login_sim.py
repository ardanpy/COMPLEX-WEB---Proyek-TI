"""Simulasi backend untuk alur login + OTP (role complex_app, query terparameter).
Pengiriman email disimulasikan dengan 'outbox' (list). DSN: env COMPLEX_TEST_DSN."""
import hashlib, hmac, os, secrets, sys
import psycopg
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

DSN = os.environ.get("COMPLEX_TEST_DSN", "dbname=complex_login")
PEPPER = secrets.token_bytes(32)          # di produksi: env backend, TIDAK di DB
ph = PasswordHasher(memory_cost=19456, time_cost=2, parallelism=1)
DUMMY = ph.hash("dummy-untuk-menyamakan-waktu")
PW = "Complex#Test2026"
GENERIC_LOGIN = "Email atau password salah"
GENERIC_OTP = "Jika email terdaftar, kode telah dikirim"
outbox = []
results = []

def check(name, ok):
    results.append(bool(ok)); print(("PASS  " if ok else "FAIL  ") + name)

app = psycopg.connect(DSN, autocommit=False); app.execute("SET ROLE complex_app"); app.commit()
owner = psycopg.connect(DSN, autocommit=True)       # hanya untuk 'time travel' & inspeksi

def code_hash(uid, purpose, code):
    return hmac.new(PEPPER, f"{uid}:{purpose}:{code}".encode(), hashlib.sha256).digest()
def sha(t): return hashlib.sha256(t.encode()).digest()

def lookup(email):
    return app.execute("SELECT * FROM fn_login_lookup(%s)", (email,)).fetchone()

def login(email, password, ip="10.0.0.5"):
    email = email.strip().lower()
    with app.transaction():
        r = lookup(email)
        if r is None:
            try: ph.verify(DUMMY, password)
            except VerifyMismatchError: pass
            app.execute("SELECT fn_login_failed(NULL,%s,%s::inet,'sim')", (email, ip))
            return 401, {"error": GENERIC_LOGIN}
        uid, h, status, locked, activated, act_ok, role = r
        if status != "aktif" or locked:
            return 401, {"error": GENERIC_LOGIN}
        try: ph.verify(h, password)
        except VerifyMismatchError:
            app.execute("SELECT fn_login_failed(%s,%s,%s::inet,'sim')", (uid, email, ip))
            return 401, {"error": GENERIC_LOGIN}
        if activated is None:                                  # login pertama -> OTP, BUKAN sesi
            if not act_ok: return 401, {"error": GENERIC_LOGIN}
            return 200, {"next": "otp", "uid": str(uid), "purpose": "activation"}
        app.execute("SELECT fn_login_succeeded(%s,%s,%s::inet,'sim')", (uid, email, ip))
        tok = secrets.token_urlsafe(32)
        app.execute("INSERT INTO sessions(user_id,token_hash,ip,expires_at) VALUES(%s,%s,%s::inet,now()+interval '8 hours')",
                    (uid, sha(tok), ip))
        return 200, {"token": tok, "role": role, "uid": str(uid)}

def send_otp(uid, email, purpose, ip="10.0.0.5"):
    code = f"{secrets.randbelow(10**6):06d}"
    with app.transaction():
        st = app.execute("SELECT fn_otp_issue(%s,%s::auth_token_purpose,%s,%s::inet)", (uid, purpose, code_hash(uid, purpose, code), ip)).fetchone()[0]
    if st == "ok": outbox.append((email, code))             # email hanya berisi kode, tanpa password
    return st

def forgot(email, ip="10.0.0.5"):
    email = email.strip().lower()
    with app.transaction(): r = lookup(email)
    if r: send_otp(r[0], email, "password_reset", ip)
    return GENERIC_OTP                                       # respons identik apa pun hasilnya

def verify_otp(uid, purpose, code):
    ticket = secrets.token_urlsafe(32)
    with app.transaction():
        st = app.execute("SELECT fn_otp_verify(%s,%s::auth_token_purpose,%s,%s,'10.0.0.5'::inet)",
                         (uid, purpose, code_hash(uid, purpose, code), sha(ticket))).fetchone()[0]
    return st, (ticket if st == "ok" else None)

def set_password(ticket, new_pw):
    if len(new_pw) < 12: return None
    with app.transaction():
        return app.execute("SELECT fn_set_password(%s,%s,'10.0.0.5'::inet)", (sha(ticket), ph.hash(new_pw))).fetchone()[0]

def me(tok):
    """Muat pengguna dari sesi lewat fn_session_user (role dari DB; tamu kedaluwarsa tidak dikenali)."""
    with app.transaction():
        return app.execute("SELECT role, user_id FROM fn_session_user(%s)", (sha(tok),)).fetchone()

def home(tok):
    """Beranda setelah login: konteks RLS diset per transaksi, lalu satu panggilan fn_home()."""
    with app.transaction():
        u = app.execute("SELECT user_id FROM fn_session_user(%s)", (sha(tok),)).fetchone()
        if not u: return None
        app.execute("SELECT set_config('app.user_id', %s, true)", (str(u[0]),))
        return app.execute("SELECT fn_home()").fetchone()[0]

def rows_as(tok, sql):
    with app.transaction():
        u = app.execute("SELECT user_id FROM fn_session_user(%s)", (sha(tok),)).fetchone()
        app.execute("SELECT set_config('app.user_id', %s, true)", (str(u[0]),))
        return app.execute(sql).fetchall()

SARI = "sari@complex.test"
# --- A. login biasa
st, a = login("admin@complex.test", PW);      check("admin login -> sesi, role admin", st == 200 and a.get("role") == "admin")
st, b = login("  BUDI@Complex.Test ", PW);     check("warga aktif login, email dinormalisasi", st == 200 and b.get("role") == "warga")
st, r1 = login("budi@complex.test", "salah"); st, r2 = login("nobody@complex.test", PW)
check("password salah & email tak dikenal -> pesan identik", r1 == r2 == {"error": GENERIC_LOGIN})
check("token dimuat, role dari DB; token palsu ditolak", me(b["token"])[0] == "warga" and me(secrets.token_urlsafe(32)) is None)
check("DB tidak menyimpan token mentah", owner.execute("SELECT count(*) FROM sessions WHERE token_hash=%s", (b["token"].encode(),)).fetchone()[0] == 0)

# --- B. login pertama (sari: password sementara dari admin -> OTP -> set password)
st, f = login(SARI, "password-sementara-salah")
check("login pertama dengan password sementara SALAH -> 401 & tidak ada email", st == 401 and not outbox)
st, f = login(SARI, PW)
check("login pertama (password sementara benar) -> diarahkan ke OTP, BUKAN sesi", st == 200 and f.get("next") == "otp" and "token" not in f)
check("belum ada sesi untuk sari", owner.execute("SELECT count(*) FROM sessions WHERE user_id=%s", (f["uid"],)).fetchone()[0] == 0)
uid = f["uid"]
check("OTP aktivasi terkirim ke outbox", send_otp(uid, SARI, "activation") == "ok" and len(outbox) == 1 and outbox[-1][0] == SARI)
check("kode tidak ada plaintext di DB", owner.execute("SELECT count(*) FROM otp_challenges WHERE row_to_json(otp_challenges)::text LIKE %s", ("%" + outbox[-1][1] + "%",)).fetchone()[0] == 0)
check("kirim ulang <60 dtk -> cooldown", send_otp(uid, SARI, "activation") == "cooldown")
good = outbox[-1][1]; bad = "000000" if good != "000000" else "000001"
st, _ = verify_otp(uid, "activation", bad);   check("OTP salah -> invalid", st == "invalid")
st, tk = verify_otp(uid, "activation", good); check("OTP benar -> ok + tiket", st == "ok" and tk)
check("password baru <12 karakter ditolak backend", set_password(tk, "pendek") is None)
check("tiket palsu ditolak", set_password(secrets.token_urlsafe(32), "PasswordBaruSari#2026") is None)
check("set password dengan tiket sah", str(set_password(tk, "PasswordBaruSari#2026")) == uid)
check("tiket tidak bisa dipakai ulang", set_password(tk, "LainLagi#12345678") is None)
st, _ = login(SARI, PW);                      check("password sementara lama tak berlaku lagi", st == 401)
st, s2 = login(SARI, "PasswordBaruSari#2026");check("login normal dengan password baru -> sesi", st == 200 and "token" in s2)

# --- C. brute force OTP: 5 salah mengunci kode
st_ = None
owner.execute("UPDATE otp_challenges SET created_at=created_at-interval '5 min', expires_at=expires_at-interval '5 min'")   # lewati cooldown
check("budi minta OTP lupa-password", send_otp(b["uid"], "budi@complex.test", "password_reset") == "ok")
real = outbox[-1][1]
res = [verify_otp(b["uid"], "password_reset", f"{i:06d}" if f"{i:06d}" != real else "999999")[0] for i in range(5)]
check("5 tebakan salah -> kode terkunci", res[-1] == "locked")
st, _ = verify_otp(b["uid"], "password_reset", real); check("kode BENAR setelah terkunci tetap ditolak", st == "invalid")

# --- D. lupa password
owner.execute("UPDATE otp_challenges SET created_at=created_at-interval '5 min', expires_at=expires_at-interval '5 min'")
n0 = len(outbox)
check("lupa password: email tak dikenal -> respons generik, tanpa email", forgot("hantu@complex.test") == GENERIC_OTP and len(outbox) == n0)
check("lupa password: respons untuk email terdaftar IDENTIK", forgot("budi@complex.test") == GENERIC_OTP and len(outbox) == n0 + 1)
st, tk = verify_otp(b["uid"], "password_reset", outbox[-1][1]); check("OTP lupa-password benar -> tiket", st == "ok")
check("set password baru berhasil", str(set_password(tk, "BudiBaru#Password26")) == b["uid"])
check("sesi lama budi DICABUT setelah ganti password", me(b["token"]) is None)
st, b2 = login("budi@complex.test", "BudiBaru#Password26"); check("budi login dengan password baru", st == 200)
owner.execute("UPDATE otp_challenges SET created_at=created_at-interval '5 min', expires_at=expires_at-interval '5 min'")
owner.execute("UPDATE users SET status='ditangguhkan' WHERE email='budi@complex.test'")
n1 = len(outbox); forgot("budi@complex.test")
check("akun ditangguhkan tidak mendapat OTP reset", len(outbox) == n1)
owner.execute("UPDATE users SET status='aktif' WHERE email='budi@complex.test'")

# --- F. tamu TANPA AKUN (sesi anonim) + beranda per peran
def gcall(sql, params=()):
    with app.transaction():
        return app.execute(sql, params).fetchone()
def guest_start(ip="10.1.0.1"):
    tok = secrets.token_urlsafe(32)
    return tok, gcall("SELECT fn_guest_session_start(%s,%s::inet,'sim')", (sha(tok), ip))[0]
def guest_home(tok): return gcall("SELECT fn_guest_home(%s)", (sha(tok),))[0]
BLK = owner.execute("SELECT id FROM blocks WHERE name='Jati 1'").fetchone()[0]   # app tanpa user_id memang tidak boleh membaca tabel blocks
def guest_report(tok, ip="10.1.0.1", name="Tamu Contoh", house="52"):
    return gcall("SELECT result, visit_id FROM fn_guest_report_create(%s,%s,'Jl. Mawar 3, Bekasi',%s::smallint,%s,'Pak Budi','Silaturahmi',NULL,NULL,now(),%s::inet)",
                 (sha(tok), name, BLK, house, ip))
owner.execute("INSERT INTO announcements(category,title,body,created_by) VALUES ('komplek','Kerja Bakti Minggu','Hadir ya','00000000-0000-0000-0000-0000000000a1'),('pengurus','Rapat Internal','Rahasia','00000000-0000-0000-0000-0000000000a1')")
owner.execute("UPDATE users SET activated_at=now() WHERE email='budi@complex.test'")
gtok, st_ = guest_start()
check("sesi tamu dimulai tanpa akun dan tanpa admin", st_ == "ok" and owner.execute("SELECT count(*) FROM users WHERE role::text='guest'").fetchone()[0] == 0)
check("DB menyimpan hash token tamu, bukan token mentah", owner.execute("SELECT count(*) FROM guest_sessions WHERE token_hash=%s", (gtok.encode(),)).fetchone()[0] == 0)
gh = guest_home(gtok)
check("beranda tamu: tombol utama lapor_tamu, 7 blok", gh["primary_action"] == "lapor_tamu" and len(gh["blocks"]) == 7 and gh["landing"] == "beranda_tamu")
titles = [a["title"] for a in gh["announcements"]]
check("tamu hanya melihat berita komplek (bukan kategori pengurus), tanpa acara/data pengguna", "Kerja Bakti Minggu" in titles and "Rapat Internal" not in titles and "events" not in gh and "user" not in gh)
check("token tamu palsu -> tidak ada beranda", guest_home(secrets.token_urlsafe(32)) is None)
def denied(sql):
    try:
        with app.transaction(): app.execute(sql)
        return False
    except psycopg.errors.InsufficientPrivilege: return True
def count_rows(sql):
    with app.transaction(): return app.execute(sql).fetchone()[0]
check("tanpa user_id, tabel bisnis tidak terbaca (tamu hanya lewat fungsi)", all(count_rows(f"SELECT count(*) FROM {t_}") == 0 for t_ in ("announcements","reports","posts","units","guest_visits")))
check("app tidak bisa membaca guest_sessions", denied("SELECT * FROM guest_sessions"))
res, vid = guest_report(gtok)
check("tamu mengirim Lapor Tamu (nama, alamat, rumah/warga tujuan, keperluan)", res == "ok" and vid is not None)
check("laporan aktif kedua dari sesi yang sama ditolak", guest_report(gtok)[0] == "active_exists")
check("beranda tamu menampilkan laporan aktifnya (sisa ~24 jam)", guest_home(gtok)["my_reports"][0]["is_active"] and guest_home(gtok)["my_reports"][0]["seconds_left"] > 86000)
check("sesi tamu tanpa token sah tidak bisa lapor", guest_report(secrets.token_urlsafe(32))[0] == "no_session")
check("input tak valid -> invalid (nama terlalu pendek)", guest_report(guest_start("10.1.0.2")[0], ip="10.1.0.2", name="X")[0] == "invalid")
for i in range(2):                                    # laporan ke-2 & ke-3 dari IP yang sama
    t2, _ = guest_start(); guest_report(t2, house="15")
check("laporan ke-4 dari IP yang sama dalam 1 jam ditolak (anti spam)", guest_report(guest_start()[0])[0] == "limit")
sess = [guest_start("10.1.0.9")[1] for _ in range(21)]
check("maks 20 sesi tamu baru per IP per jam", sess.count("ok") == 20 and sess[-1] == "limit")
check("budi (tuan rumah) melihat tamu di berandanya; admin melihat semuanya",
      home(b2["token"])["stats"]["guests_at_my_unit"] >= 1 and home(a["token"])["stats"]["guests_active"] >= 3)
ha, hw = home(a["token"]), home(b2["token"])
check("beranda admin/warga: landing berbeda, statistik sesuai peran, tanpa email/hash",
      ha["landing"] == "beranda_admin" and "reports_new" in ha["stats"] and hw["landing"] == "beranda_warga"
      and "my_unpaid_dues" in hw["stats"] and "reports_new" not in hw["stats"] and "password" not in str(ha) + str(hw))
check("tamu mengakhiri laporannya sendiri; sesi lain tidak bisa",
      gcall("SELECT fn_guest_report_end(%s,%s,'selesai')", (sha(guest_start("10.1.0.3")[0]), vid))[0] == "not_found"
      and gcall("SELECT fn_guest_report_end(%s,%s,'selesai')", (sha(gtok), vid))[0] == "ok")
owner.execute("UPDATE guest_sessions SET created_at=created_at-interval '2 days', expires_at=expires_at-interval '2 days' WHERE token_hash=%s", (sha(gtok),))
check("cookie tamu kedaluwarsa (24 jam): beranda kosong & tidak bisa lapor", guest_home(gtok) is None and guest_report(gtok)[0] == "no_session")

# --- E. injeksi & kelancangan hak akses
st, _ = login("' OR '1'='1' --", "x");   check("SQLi di email login -> 401", st == 401)
check("SQLi di email lupa-password -> generik, tak ada email", forgot("x'; DROP TABLE users;--") == GENERIC_OTP)
check("tabel users utuh", owner.execute("SELECT to_regclass('users') IS NOT NULL").fetchone()[0])
def denied(sql):
    try:
        with app.transaction(): app.execute(sql)
        return False
    except psycopg.errors.InsufficientPrivilege: return True
check("app tak bisa baca otp_challenges", denied("SELECT * FROM otp_challenges"))
check("app tak bisa baca/menulis auth_tokens", denied("SELECT * FROM auth_tokens") and denied("DELETE FROM auth_tokens"))
check("app tak bisa menandai akun aktif sendiri", denied("UPDATE users SET activated_at=now()"))
check("email berisi kode saja, tanpa password", all(PW not in c and len(c) == 6 for _, c in outbox))
check("login_attempts mencatat kegagalan", owner.execute("SELECT count(*) FROM login_attempts WHERE success=false").fetchone()[0] >= 3)

app.rollback(); app.close(); owner.close()
print("-" * 48); print(f"LULUS {sum(results)} / {len(results)}")
sys.exit(0 if all(results) else 1)
