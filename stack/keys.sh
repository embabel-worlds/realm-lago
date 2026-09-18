#!/bin/sh
# Generate Lago's boot secrets once. A second `up` finds the file and leaves it alone —
# regenerating would orphan every value Lago already encrypted with the old ones.
set -eu
[ -s /state/lago.env ] && { echo "keys: already generated"; exit 0; }

hex() { openssl rand -hex "$1"; }
umask 077
{
  echo "SECRET_KEY_BASE=$(hex 64)"
  echo "LAGO_RSA_PRIVATE_KEY=$(openssl genrsa 2048 2>/dev/null | base64 | tr -d '\n')"
  echo "LAGO_ENCRYPTION_PRIMARY_KEY=$(hex 16)"
  echo "LAGO_ENCRYPTION_DETERMINISTIC_KEY=$(hex 16)"
  echo "LAGO_ENCRYPTION_KEY_DERIVATION_SALT=$(hex 16)"
  echo "LAGO_ORG_API_KEY=$(hex 20)"
  # Lago's sign-in form enforces a mixed-case, digit and symbol password.
  echo "LAGO_ORG_USER_PASSWORD=Demo-$(hex 6)-A1!"
} > /state/lago.env
chmod 644 /state/lago.env
echo "keys: generated"
