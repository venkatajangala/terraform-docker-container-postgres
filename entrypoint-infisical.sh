#!/bin/bash
set -e

echo "=== Starting Infisical Secrets Management Server ==="

# Configuration
INFISICAL_PORT=${INFISICAL_PORT:-8020}
INFISICAL_DB_HOST=${INFISICAL_DB_HOST:-localhost}
INFISICAL_DB_PORT=${INFISICAL_DB_PORT:-5437}
INFISICAL_DB_NAME=${INFISICAL_DB_NAME:-infisical}
INFISICAL_DB_USER=${INFISICAL_DB_USER:-infisical}
INFISICAL_DB_PASSWORD=${INFISICAL_DB_PASSWORD:-infisical-secure-password}

# Wait for PostgreSQL backend to be ready (if using database backend)
if [ -n "$INFISICAL_DB_HOST" ]; then
  echo "Waiting for database backend at $INFISICAL_DB_HOST:$INFISICAL_DB_PORT..."
  max_attempts=30
  attempt=0
  until PGPASSWORD="$INFISICAL_DB_PASSWORD" psql -h "$INFISICAL_DB_HOST" -p "$INFISICAL_DB_PORT" -U "$INFISICAL_DB_USER" -d "$INFISICAL_DB_NAME" -c "SELECT 1" > /dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ $attempt -gt $max_attempts ]; then
      echo "Database backend failed to start after $max_attempts attempts"
      exit 1
    fi
    echo "Database not ready, waiting... ($attempt/$max_attempts)"
    sleep 2
  done
  echo "Database backend is ready!"
fi

# Create necessary directories
mkdir -p /var/lib/infisical /var/log/infisical

# Initialize Infisical configuration if not present
if [ ! -f /etc/infisical/.initialized ]; then
  echo "Initializing Infisical for first run..."
  
  # Set environment variables for Infisical
  export INFISICAL_PORT=$INFISICAL_PORT
  export DATABASE_URL="postgresql://${INFISICAL_DB_USER}:${INFISICAL_DB_PASSWORD}@${INFISICAL_DB_HOST}:${INFISICAL_DB_PORT}/${INFISICAL_DB_NAME}"
  export NODE_ENV=production
  
  # Create initialization marker
  touch /etc/infisical/.initialized
  echo "Infisical initialization complete"
fi

# Start Infisical server
echo "Starting Infisical server on port $INFISICAL_PORT..."
exec infisical run -- node /app/server.js
