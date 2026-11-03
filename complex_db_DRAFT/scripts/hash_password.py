#!/usr/bin/env python3
"""Hash password dengan Argon2id (parameter OWASP: m=19 MiB, t=2, p=1).
Password dibaca dari env var COMPLEX_PASSWORD atau prompt (tidak lewat argumen/riwayat shell)."""
import getpass, os, sys
from argon2 import PasswordHasher

pw = os.environ.get("COMPLEX_PASSWORD") or getpass.getpass("Password: ")
if len(pw) < 12:
    sys.exit("Password minimal 12 karakter.")
print(PasswordHasher(memory_cost=19456, time_cost=2, parallelism=1).hash(pw))
