# ============================================================================
# Infisical Secrets Management Infrastructure
# NOTE: random_password resources are defined in main-ha.tf
# ============================================================================

# ============================================================================
# Redis Cache (required by Infisical server)
# ============================================================================

resource "docker_image" "redis" {
  count = var.infisical_enabled ? 1 : 0
  name  = "redis:7-alpine"
}

resource "docker_container" "infisical_redis" {
  count   = var.infisical_enabled ? 1 : 0
  name    = "infisical-redis"
  image   = docker_image.redis[0].image_id
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  healthcheck {
    test     = ["CMD", "redis-cli", "ping"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }
}

# ============================================================================
# Infisical PostgreSQL Backend Database
# ============================================================================

resource "docker_image" "postgres_infisical" {
  count = var.infisical_enabled ? 1 : 0
  name  = "postgres:18-bookworm"
}

resource "docker_volume" "infisical_db_data" {
  count = var.infisical_enabled ? 1 : 0
  name  = "infisical-db-data"
}

resource "docker_container" "infisical_postgres" {
  count   = var.infisical_enabled ? 1 : 0
  name    = "infisical-postgres"
  image   = docker_image.postgres_infisical[0].image_id
  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=infisical",
    "POSTGRES_USER=infisical",
    "POSTGRES_PASSWORD=${random_password.infisical_db_password.result}",
    "PGDATA=/var/lib/postgresql/data/pgdata"
  ]

  ports {
    internal = 5432
    external = var.infisical_db_port
  }

  mounts {
    target = "/var/lib/postgresql/data"
    source = docker_volume.infisical_db_data[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U infisical -d infisical"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }
}

# ============================================================================
# Infisical Secrets Management Service
# ============================================================================

resource "docker_image" "infisical" {
  count = var.infisical_enabled ? 1 : 0
  name  = "infisical/infisical:latest"
}

resource "docker_volume" "infisical_data" {
  count = var.infisical_enabled ? 1 : 0
  name  = "infisical-data"
}

resource "docker_container" "infisical" {
  count   = var.infisical_enabled ? 1 : 0
  name    = "infisical"
  image   = docker_image.infisical[0].image_id
  restart = "unless-stopped"

  env = [
    "DB_CONNECTION_URI=postgresql://infisical:${random_password.infisical_db_password.result}@infisical-postgres:5432/infisical",
    "REDIS_URL=redis://infisical-redis:6379",
    "ENCRYPTION_KEY=${substr(random_password.infisical_api_key.result, 0, 32)}",
    "AUTH_SECRET=${random_password.pgbouncer_admin_password.result}",
    "SITE_URL=http://localhost:${var.infisical_port}",
    "PORT=8080",
    "NODE_ENV=production"
  ]

  ports {
    internal = 8080
    external = var.infisical_port
  }

  mounts {
    target = "/var/lib/infisical"
    source = docker_volume.infisical_data[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [
    docker_container.infisical_postgres,
    docker_container.infisical_redis
  ]

  healthcheck {
    test     = ["CMD", "curl", "-f", "http://localhost:8080/api/status"]
    interval = "15s"
    timeout  = "5s"
    retries  = 3
  }
}

# ============================================================================
# Initialize Secrets in Infisical
# ============================================================================

resource "null_resource" "infisical_init_secrets" {
  count = var.infisical_enabled && var.generate_new_passwords ? 1 : 0

  triggers = {
    infisical_container_id = try(docker_container.infisical[0].id, "")
  }

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e
      
      echo "Waiting for Infisical to be ready..."
      sleep 5
      
      max_retries=30
      attempt=0
      until curl -s http://localhost:${var.infisical_port}/api/status > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -gt $max_retries ]; then
          echo "Infisical failed to start after $max_retries attempts"
          exit 1
        fi
        echo "Attempt $attempt/$max_retries: Waiting for Infisical..."
        sleep 2
      done
      
      echo "Infisical is ready! Creating secrets..."
      echo "Secrets should be created in Infisical via:"
      echo "1. Navigate to: http://localhost:${var.infisical_port}"
      echo "2. Create project and environment"
      echo "3. Add the following secrets:"
      echo "   - db-admin-password: ${random_password.db_admin_password.result}"
      echo "   - db-replication-password: ${random_password.db_replication_password.result}"
      echo "   - pgbouncer-admin-password: ${random_password.pgbouncer_admin_password.result}"
    EOT
  }

  depends_on = [docker_container.infisical]
}

# ============================================================================
# Output: Infisical Configuration
# ============================================================================

output "infisical_url" {
  description = "Infisical service URL"
  value       = var.infisical_enabled ? "http://localhost:${var.infisical_port}" : "Infisical disabled"
}

output "infisical_db_host" {
  description = "Infisical PostgreSQL database host"
  value       = var.infisical_enabled ? "infisical-postgres" : "N/A"
}

output "infisical_db_port" {
  description = "Infisical PostgreSQL database port"
  value       = var.infisical_enabled ? var.infisical_db_port : "N/A"
}

output "generated_passwords" {
  description = "Generated passwords for initial setup (store securely in Infisical)"
  sensitive   = true
  value = var.generate_new_passwords ? {
    db_admin_password        = random_password.db_admin_password.result
    db_replication_password  = random_password.db_replication_password.result
    pgbouncer_admin_password = random_password.pgbouncer_admin_password.result
    infisical_api_key        = random_password.infisical_api_key.result
  } : {}
}
