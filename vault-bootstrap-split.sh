#!/usr/bin/env bash
# vault-bootstrap-split.sh
# Splits .vault-bootstrap/approle_<role>.json into separate role_id and secret_id
# plain-text files expected by vault/agent/agent.hcl auto_auth.
#
# Usage:
#   bash vault-bootstrap-split.sh [role-name]   # default: pg-role
#
# Run this after initial bootstrap or after rotating the secret_id.
# Output files (.vault-bootstrap/role_id, .vault-bootstrap/secret_id) are
# gitignored via .vault-bootstrap/ — never commit them.
set -euo pipefail

ROLE="${1:-pg-role}"
OUT_DIR=".vault-bootstrap"
JSON="${OUT_DIR}/approle_${ROLE}.json"

if [ ! -f "$JSON" ]; then
  echo "ERROR: $JSON not found. Run vault-bootstrap.sh first." >&2
  exit 1
fi

if ! command -v jq &>/dev/null && ! command -v python3 &>/dev/null; then
  echo "ERROR: jq or python3 required." >&2
  exit 1
fi

if command -v jq &>/dev/null; then
  ROLE_ID=$(jq -r '.role_id' "$JSON")
  SECRET_ID=$(jq -r '.secret_id' "$JSON")
else
  ROLE_ID=$(python3 -c "import sys,json; d=json.load(open('$JSON')); print(d['role_id'])")
  SECRET_ID=$(python3 -c "import sys,json; d=json.load(open('$JSON')); print(d['secret_id'])")
fi

printf '%s' "$ROLE_ID"  > "${OUT_DIR}/role_id"
printf '%s' "$SECRET_ID" > "${OUT_DIR}/secret_id"
# 644: owner can write, vault-agent container user (uid=100) can read via world-read bit
chmod 644 "${OUT_DIR}/role_id" "${OUT_DIR}/secret_id"

echo "Split complete:"
echo "  ${OUT_DIR}/role_id   -> ${ROLE_ID}"
echo "  ${OUT_DIR}/secret_id -> (written, not shown)"
