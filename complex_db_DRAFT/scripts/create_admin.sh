#!/usr/bin/env bash
# Contoh:  ADMIN_EMAIL=ketua@contoh.id ADMIN_NAME="Ketua RT" DB=complex ./create_admin.sh [email_admin_pembuat]
# Password diminta lewat prompt (atau COMPLEX_PASSWORD). Hash dibuat client-side (Argon2id).
set -euo pipefail
: "${ADMIN_EMAIL:?isi ADMIN_EMAIL}" "${ADMIN_NAME:?isi ADMIN_NAME}" "${DB:=complex}"
HASH="$(python3 "$(dirname "$0")/hash_password.py")"
psql -d "$DB" -v ON_ERROR_STOP=1 -v email="$ADMIN_EMAIL" -v name="$ADMIN_NAME" -v hash="$HASH" \
     -v creator="${1:-}" -f "$(dirname "$0")/create_admin.sql"
