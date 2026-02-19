#!/bin/bash
set -e

# Wait for etcd to be ready
echo "Waiting for etcd to be ready..."
until curl -s http://etcd:2379/version > /dev/null 2>&1; do
  echo "etcd is unavailable - sleeping"
  sleep 2
done
echo "etcd is ready"

# Set up PostgreSQL directories with proper permissions
mkdir -p /var/lib/postgresql/18/main
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql

# Initialize pgbackrest if not already done
if [ ! -f /etc/pgbackrest/.initialized ]; then
  echo "Initializing pgbackrest..."
  mkdir -p /etc/pgbackrest
  mkdir -p /var/lib/pgbackrest
  chown -R postgres:postgres /var/lib/pgbackrest
  mkdir -p /var/log/pgbackrest
  chown -R postgres:postgres /var/log/pgbackrest
  touch /etc/pgbackrest/.initialized
fi

# Execute the original entrypoint
exec sudo -u postgres "$@"