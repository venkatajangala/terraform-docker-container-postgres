
# ============================================================================
# Infisical Secrets Management Infrastructure
# ============================================================================

# Generate secure random passwords for initial setup
resource "random_password" "db_admin_password" {
  length  = var.password_length
  special = true
}

resource "random_password" "db_replication_password" {
  length  = var.password_length
  special = true
}

resource "random_password" "pgbouncer_admin_password" {
  length  = var.password_length
  special = true
}

resource "random_password" "infisical_api_key" {
  length  = 32
  special = true
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
    "POSTGRES_PASSWORD=infisical-secure-password",
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
  name  = "infisical:latest"
  build {
    context    = path.module
    dockerfile = "Dockerfile.infisical"
  }
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
    "INFISICAL_PORT=8020",
    "INFISICAL_DB_HOST=infisical-postgres",
    "INFISICAL_DB_PORT=5432",
    "INFISICAL_DB_NAME=infisical",
    "INFISICAL_DB_USER=infisical",
    "INFISICAL_DB_PASSWORD=infisical-secure-password",
    "NODE_ENV=production"
  ]

  ports {
    internal = 8020
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
    docker_container.infisical_postgres
  ]

  healthcheck {
    test     = ["CMD", "curl", "-f", "http://localhost:8020/api/v1/health"]
    interval = "15s"
    timeout  = "5s"
    retries  = 3
  }
}

# ============================================================================
# Initialize Secrets in Infisical
# ============================================================================

# This local provisioner initializes Infisical with required secrets
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
      
      # Try to connect to Infisical
      max_retries=30
      attempt=0
      until curl -s http://localhost:${var.infisical_port}/api/v1/health > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -gt $max_retries ]; then
          echo "Infisical failed to start after $max_retries attempts"
          exit 1
        fi
        echo "Attempt $attempt/$max_retries: Waiting for Infisical..."
        sleep 2
      done
      
      echo "Infisical is ready! Creating secrets..."
      
      # Set default API key if not provided
      API_KEY="${var.infisical_api_key}"
      if [ -z "$API_KEY" ]; then
        API_KEY="${random_password.infisical_api_key.result}"
        echo "Generated new Infisical API key: $API_KEY"
      fi
      
      # Note: Secret creation would typically be done via Infisical UI or CLI
      # This is a placeholder for documentation
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
    db_admin_password         = random_password.db_admin_password.result
    db_replication_password   = random_password.db_replication_password.result
    pgbouncer_admin_password  = random_password.pgbouncer_admin_password.result
    infisical_api_key         = random_password.infisical_api_key.result
  } : {}
}
