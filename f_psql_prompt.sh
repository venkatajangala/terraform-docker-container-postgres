#!/bin/bash
# f_psql_prompt.sh
# Connects to PostgreSQL via PgBouncer pooler or the Patroni primary, resolving
# the password from Vault KV v2 (falls back to Terraform output if Vault is down).
#
# Usage:
#   source f_psql_prompt.sh
#   f_psql_prompt [PgBouncerPSQL|ServerPSQL] [username] [--cmd "SQL"]
#
# Examples:
#   f_psql_prompt PgBouncerPSQL postgres
#   f_psql_prompt ServerPSQL pgadmin
#   f_psql_prompt PgBouncerPSQL pgadmin --cmd "SELECT version();"  # non-interactive

# ── Module-level configuration ────────────────────────────────────────────────
# Override these by exporting vars before sourcing this file.
PSQL_PROMPT_DIR="${PSQL_PROMPT_DIR:-${HOME}/terraform-docker-container-postgres}"
PSQL_VAULT_ADDR="${PSQL_VAULT_ADDR:-http://localhost:8200}"

# ── Helper: resolve the PostgreSQL password ───────────────────────────────────
# Resolution order:
#   1. Vault KV v2  (secret/data/pg/postgres → postgres_password)
#   2. Terraform output  (pg_primary_endpoint connection string)
#   3. Empty string  (psql will prompt interactively)
_psql_resolve_password() {
  local proj_dir="${PSQL_PROMPT_DIR}"
  local vault_addr="${PSQL_VAULT_ADDR}"
  local tfvars="${proj_dir}/ha-test.tfvars"
  local vault_token=""
  local init_file="${proj_dir}/.vault-bootstrap/vault-init.json"

  # In server mode, the root token is written to .vault-bootstrap/vault-init.json
  # on first deploy by vault-bootstrap.sh.
  if [ -f "$init_file" ]; then
    vault_token=$(jq -r '.root_token // empty' "$init_file" 2>/dev/null || true)
  fi

  # 1. Vault KV v2
  if curl -sf --max-time 3 "${vault_addr}/v1/sys/health" > /dev/null 2>&1; then
    local pw
    pw=$(curl -sf --max-time 5 \
      -H "X-Vault-Token: ${vault_token}" \
      "${vault_addr}/v1/secret/data/pg/postgres" 2>/dev/null \
      | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['data']['data']['postgres_password'])
except Exception:
    pass
" 2>/dev/null || true)
    if [ -n "$pw" ]; then
      echo "$pw"
      return 0
    fi
  fi

  # 2. Terraform sensitive output — pg_primary_endpoint embeds the password
  local conn
  conn=$(cd "$proj_dir" && terraform output -raw pg_primary_endpoint 2>/dev/null || true)
  if [ -n "$conn" ]; then
    local pw
    pw=$(python3 -c "
from urllib.parse import urlparse
import sys
u = urlparse(sys.argv[1])
print(u.password or '')
" "$conn" 2>/dev/null || true)
    if [ -n "$pw" ]; then
      echo "$pw"
      return 0
    fi
  fi

  # 3. Return empty — psql will prompt
  echo ""
}

# ── Helper: find the current Patroni primary via REST API ────────────────────
_psql_find_leader() {
  local leader
  leader=$(curl -sf --max-time 3 "http://localhost:8008/leader" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null || true)
  echo "${leader:-pg-node-1}"
}

# ── Main function ─────────────────────────────────────────────────────────────
f_psql_prompt() {

  _usage() {
    echo
    echo "Usage:  f_psql_prompt [PgBouncerPSQL|ServerPSQL] [username] [--cmd \"SQL\"]"
    echo
    echo "  PgBouncerPSQL  — connect via PgBouncer pooler  (port 6432)"
    echo "  ServerPSQL     — connect directly to Patroni primary (port 5432)"
    echo "  --cmd \"SQL\"    — run SQL non-interactively (scripts / tests)"
    echo
    echo "Examples:"
    echo "  f_psql_prompt PgBouncerPSQL postgres"
    echo "  f_psql_prompt ServerPSQL pgadmin"
    echo "  f_psql_prompt PgBouncerPSQL pgadmin --cmd \"SELECT version();\""
    echo
  }

  if [ -z "$1" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    _usage
    return 0
  fi

  local mode="$1"
  local pg_user="${2:-pgadmin}"
  local sql_cmd=""

  # Parse optional --cmd flag
  local i=1
  while [ $i -le $# ]; do
    if [ "${!i}" = "--cmd" ]; then
      i=$((i + 1))
      sql_cmd="${!i}"
    fi
    i=$((i + 1))
  done

  echo
  echo "PSQL Prompt — Connecting via ${mode}..."
  echo

  local pg_password
  pg_password=$(_psql_resolve_password)

  if [ -z "$pg_password" ]; then
    echo "  Warning: password not resolved — psql will prompt."
  else
    if curl -sf --max-time 2 "${PSQL_VAULT_ADDR}/v1/sys/health" > /dev/null 2>&1; then
      echo "  Password source: Vault (${PSQL_VAULT_ADDR})"
    else
      echo "  Password source: Terraform output (pg_primary_endpoint)"
    fi
  fi

  case "$mode" in

    PgBouncerPSQL)
      echo "  Endpoint: pgbouncer-1:6432  user=${pg_user}"
      [ -n "$sql_cmd" ] && echo "  Command:  ${sql_cmd}"
      echo
      if [ -n "$sql_cmd" ]; then
        docker exec -e PGPASSWORD="$pg_password" pgbouncer-1 \
          psql -h localhost -p 6432 -U "$pg_user" -d postgres -c "$sql_cmd"
      else
        docker exec -it -e PGPASSWORD="$pg_password" pgbouncer-1 \
          psql -h localhost -p 6432 -U "$pg_user" -d postgres
      fi
      ;;

    ServerPSQL)
      local leader
      leader=$(_psql_find_leader)
      echo "  Primary:  ${leader}:5432  user=${pg_user}"
      [ -n "$sql_cmd" ] && echo "  Command:  ${sql_cmd}"
      echo
      if [ -n "$sql_cmd" ]; then
        docker exec -e PGPASSWORD="$pg_password" "$leader" \
          psql -h localhost -p 5432 -U "$pg_user" -d postgres -c "$sql_cmd"
      else
        docker exec -it -e PGPASSWORD="$pg_password" "$leader" \
          psql -h localhost -p 5432 -U "$pg_user" -d postgres
      fi
      ;;

    *)
      echo "ERROR: Unknown mode '${mode}'. Choose 'PgBouncerPSQL' or 'ServerPSQL'."
      _usage
      unset pg_password 2>/dev/null || true
      return 1
      ;;
  esac

  local exit_code=$?
  unset pg_password 2>/dev/null || true
  return $exit_code

} # f_psql_prompt
