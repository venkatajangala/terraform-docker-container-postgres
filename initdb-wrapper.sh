#!/bin/bash
# Patroni initdb wrapper - ensures pg_hba.conf is created with proper entries
D_PATH=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -D)
      D_PATH="$2"
      ARGS+=("$1" "$2")
      shift 2
      ;;
    --pgdata=*)
      D_PATH="${1#*=}"
      ARGS+=("$1")
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

/usr/lib/postgresql/18/bin/initdb.real "${ARGS[@]}"

if [ -n "$D_PATH" ] && [ -d "$D_PATH" ]; then
  cat > "$D_PATH/pg_hba.conf" <<'EOF'
# PostgreSQL Client Authentication Configuration
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    replication     all             172.20.0.0/16           scram-sha-256
host    all             all             172.20.0.0/16           scram-sha-256
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
EOF
  chmod 600 "$D_PATH/pg_hba.conf"
  chmod 700 "$D_PATH"
fi
