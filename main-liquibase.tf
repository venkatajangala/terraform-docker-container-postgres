# ============================================================================
# Liquibase Database Migration Integration
# ============================================================================

resource "docker_image" "liquibase" {
  count = var.liquibase_enabled ? 1 : 0
  name  = "liquibase:ha"
  build {
    context    = path.module
    dockerfile = "Dockerfile.liquibase"
  }
}

resource "docker_container" "liquibase" {
  count   = var.liquibase_enabled ? 1 : 0
  name    = "liquibase-migrations"
  image   = docker_image.liquibase[0].image_id
  restart = "no"

  # Environment variables for database connection
  # Connects via PgBouncer (session-mode pool) for HA-aware routing
  env = [
    "DB_HOST=pgbouncer-1",
    "DB_PORT=6432",
    "DB_NAME=postgres_liquibase",
    # Use postgres superuser — it is in PgBouncer's userlist and has full DDL privileges for migrations
    "DB_USER=postgres",
    "DB_PASSWORD=${local.postgres_password}",
    "MAX_RETRIES=${var.liquibase_max_retries}",
    "RETRY_INTERVAL=${var.liquibase_retry_interval}",
    # Liquibase properties
    "LIQUIBASE_DRIVER_CLASS_NAME=org.postgresql.Driver",
    "LIQUIBASE_URL=jdbc:postgresql://pgbouncer-1:6432/postgres_liquibase",
    "LIQUIBASE_USERNAME=postgres",
    "LIQUIBASE_PASSWORD=${local.postgres_password}",
    "LIQUIBASE_CHANGELOG_FILE=changelog/db.changelog-master.yml",
  ]

  # Mount changelog directory
  mounts {
    target    = "/liquibase/changelog"
    source    = abspath("${path.module}/liquibase/changelog")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  # Resource limits
  memory      = var.liquibase_memory_mb
  memory_swap = var.liquibase_memory_mb

  # Logging configuration
  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  # Container will exit after migrations complete (one-shot)
  rm = false
  must_run = false

  # Dependency: wait for PgBouncer (which waits for PostgreSQL HA cluster)
  depends_on = [docker_container.pgbouncer, docker_image.liquibase]
}
