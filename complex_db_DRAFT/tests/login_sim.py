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
    return app.execute("SELECT id, password_hash, status, locked_until > now(), activated_at, activation_expires_at > now(), role, access_expires_at "
                       "FROM users WHERE email=%s", (email,)).fetchone()

def login(email, password, ip="10.0.0.5"):
    email = email.strip().lower()
    with app.transaction():
        r = lookup(email)
        if r is None:
            try: ph.verify(DUMMY, password)
            except VerifyMismatchError: pass
            app.execute("SELECT fn_login_failed(NULL,%s,%s::inet,'sim')", (email, ip))
            return 401, {"error": GENERIC_LOGIN}
        uid, h, status, locked, activated, act_ok, role, access_until = r
        if status != "aktif" or locked:
            return 401, {"error": GENERIC_LOGIN}
        try: ph.verify(h, password)
        except VerifyMismatchError:
            app.execute("SELECT fn_login_failed(%s,%s,%s::inet,'sim')", (uid, email, ip))
            return 401, {"error": GENERIC_LOGIN}
        if role == "guest" and app.execute("SELECT %s::timestamptz <= now()", (access_until,)).fetchone()[0]:
            return 401, {"error": GENERIC_LOGIN}               # akses tamu berakhir: pesan tetap generik
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

# --- F. role guest (tamu) + beranda per role
st, g = login("tamu@complex.test", PW)
check("tamu login -> sesi, role guest", st == 200 and g.get("role") == "guest")
check("sesi tamu dipotong sampai batas akses (<= 24 jam)", owner.execute("SELECT expires_at <= now()+interval '24 hours 1 minute' FROM sessions WHERE token_hash=%s", (sha(g["token"]),)).fetchone()[0])
ha, hw, hg = home(a["token"]), home(b2["token"]), home(g["token"])
check("beranda admin: landing + statistik pengelola", ha["landing"] == "beranda_admin" and "reports_new" in ha["stats"])
check("beranda warga: landing + statistik miliknya", hw["landing"] == "beranda_warga" and "my_unpaid_dues" in hw["stats"] and "reports_new" not in hw["stats"])
check("beranda tamu: berita + tombol utama lapor_tamu, tanpa rumah", hg["landing"] == "beranda_tamu" and set(hg["stats"]) == {"my_active_visit", "primary_action"} and hg["stats"]["primary_action"] == "lapor_tamu" and hg["user"]["unit"] is None)
check("tidak ada hash password/email di payload beranda", "password" not in str(hg) + str(hw) + str(ha) and "@" not in str(hg))
for t_ in ("reports", "posts", "dues_bills", "facility_requests", "security_guards", "v_community_members"):
    if rows_as(g["token"], f"SELECT 1 FROM {t_}"): check(f"tamu tidak boleh membaca {t_}", False); break
else: check("tamu tidak dapat membaca laporan, komunitas, iuran, fasilitas, satpam, anggota", True)
def write_denied(tok, sql):
    try:
        rows_as(tok, sql); return False
    except psycopg.errors.InsufficientPrivilege: return True
    except psycopg.errors.Error as e: return "row-level security" in str(e)
check("tamu tidak bisa membuat laporan/postingan (RLS)",
      write_denied(g["token"], "INSERT INTO reports(reporter_id,category,title,description,location_text) VALUES(current_setting('app.user_id')::uuid,'lainnya','x1','x','x')")
      and write_denied(g["token"], "INSERT INTO posts(author_id,body) VALUES(current_setting('app.user_id')::uuid,'halo')"))
with app.transaction():
    app.execute("SELECT set_config('app.user_id', %s, true)", (g["uid"],))
    app.execute("INSERT INTO guest_visits(reporter_id,visitor_name,visitor_address,host_unit_id,host_name,purpose) VALUES(%s,'Tamu Contoh','Jl. Mawar 3, Bekasi',(SELECT unit_id FROM users WHERE email='budi@complex.test'),'Pak Budi','Silaturahmi')", (g["uid"],))
check("tamu membuat Lapor Tamu; beranda menampilkan sisa 24 jam", home(g["token"])["stats"]["my_active_visit"]["valid_until"] is not None)
check("budi (tuan rumah) melihat 1 tamu aktif di berandanya", home(b2["token"])["stats"]["guests_at_my_unit"] == 1)
# kedaluwarsa (time travel lewat koneksi pemilik)
owner.execute("ALTER TABLE users DISABLE TRIGGER users_guard")
owner.execute("UPDATE users SET created_at=created_at-interval '3 days', access_expires_at=now()-interval '1 minute' WHERE email='tamu@complex.test'")
owner.execute("ALTER TABLE users ENABLE TRIGGER users_guard")
check("tamu kedaluwarsa: sesi lama tidak dikenali & beranda kosong", me(g["token"]) is None and home(g["token"]) is None)
st, rg = login("tamu@complex.test", PW)
check("tamu kedaluwarsa: login ditolak dengan pesan generik", st == 401 and rg == {"error": GENERIC_LOGIN})

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
