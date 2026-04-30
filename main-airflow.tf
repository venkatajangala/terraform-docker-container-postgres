# ============================================================================
# Apache Airflow ETL Platform
# Enabled via: airflow_enabled = true in ha-test.tfvars
#
# Dependency chain:
#   pg_nodes → pgbouncer → null_resource.airflow_db_setup (creates airflow DB + user)
#            → airflow_init (db migrate + admin user)
#            → airflow_webserver
#            → airflow_scheduler
#
# Metadata DB connection:
#   airflow-entrypoint.sh discovers the Patroni primary via REST API
#   (pg-node-1:8008 … pg-node-3:8008 — internal Docker DNS) and builds
#   AIRFLOW__DATABASE__SQL_ALCHEMY_CONN pointing directly to that node at
#   port 5432, bypassing PgBouncer. This prevents "read-only transaction"
#   errors that occur when Patroni elects a replica to primary after deploy.
# ============================================================================

# ── Secrets ──────────────────────────────────────────────────────────────────

resource "random_password" "airflow_db_password" {
  count            = var.airflow_enabled ? 1 : 0
  length           = 32
  special          = true
  override_special = "-_"
}

resource "random_password" "airflow_admin_password" {
  count   = (var.airflow_enabled && var.airflow_admin_password == "") ? 1 : 0
  length  = 20
  special = false
}

# Fernet key: Airflow requires a URL-safe base64-encoded 32-byte key.
# random_id.b64_url gives exactly that — 32 random bytes, URL-safe base64.
resource "random_id" "airflow_fernet_key" {
  count       = var.airflow_enabled ? 1 : 0
  byte_length = 32
}

locals {
  airflow_db_password    = var.airflow_enabled ? random_password.airflow_db_password[0].result : ""
  airflow_fernet_key     = var.airflow_enabled ? random_id.airflow_fernet_key[0].b64_url : ""
  airflow_admin_password = (var.airflow_enabled && var.airflow_admin_password != "") ? var.airflow_admin_password : (var.airflow_enabled ? random_password.airflow_admin_password[0].result : "")

  # ETL connection string (for DAGs connecting to the HA postgres cluster via PgBouncer)
  airflow_etl_conn = var.airflow_enabled ? "postgresql://pgadmin:${local.postgres_password}@pgbouncer-1:6432/postgres?sslmode=disable" : ""

  # Shared env vars for all Airflow containers.
  # AIRFLOW__DATABASE__SQL_ALCHEMY_CONN is NOT set here — airflow-entrypoint.sh
  # discovers the Patroni primary at runtime and builds the URL dynamically.
  airflow_common_env = var.airflow_enabled ? [
    # Credentials passed separately so airflow-entrypoint.sh can build the URL
    # pointing directly at the current Patroni primary (bypasses PgBouncer).
    "AIRFLOW_DB_USER=airflow_user",
    "AIRFLOW_DB_PASSWORD=${local.airflow_db_password}",
    "AIRFLOW_DB_NAME=airflow",
    "AIRFLOW__CORE__EXECUTOR=LocalExecutor",
    "AIRFLOW__CORE__FERNET_KEY=${local.airflow_fernet_key}",
    "AIRFLOW__CORE__LOAD_EXAMPLES=False",
    "AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION=True",
    "AIRFLOW__WEBSERVER__BASE_URL=http://localhost:${var.airflow_port}",
    "AIRFLOW__WEBSERVER__EXPOSE_CONFIG=True",
    # ETL connection available to all DAGs via Airflow connection ID "postgres_ha"
    "AIRFLOW_CONN_POSTGRES_HA=${local.airflow_etl_conn}",
  ] : []
}

# ── Custom Airflow Image ──────────────────────────────────────────────────────

resource "docker_image" "airflow_custom" {
  count = var.airflow_enabled ? 1 : 0
  name  = "custom-airflow-etl:latest"
  build {
    context    = "."
    dockerfile = "Dockerfile.airflow"
    no_cache   = false
  }
}

# ── DAGs directory (host bind-mount) ─────────────────────────────────────────

resource "null_resource" "create_dags_dir" {
  count = var.airflow_enabled ? 1 : 0
  provisioner "local-exec" {
    command = "mkdir -p ${path.cwd}/dags"
  }
}

# ── Airflow DB + User setup ────────────────────────────────────────────────────
# Creates airflow_user role and airflow database directly on the Patroni primary
# via docker exec + psql. Passwords flow through environment variables only —
# never on the command line or in Liquibase changesets.
# Runs before both Liquibase and airflow_init to guarantee the DB exists.

resource "null_resource" "airflow_db_setup" {
  count = var.airflow_enabled ? 1 : 0

  triggers = {
    # Re-run when the password changes (destroy + apply cycle)
    airflow_db_password = local.airflow_db_password
  }

  provisioner "local-exec" {
    environment = {
      AIRFLOW_DB_PASSWORD = local.airflow_db_password
      POSTGRES_PASSWORD   = local.postgres_password
    }
    command = "bash ${path.module}/setup-airflow-db.sh"
  }

  # Wait for PgBouncer (which proves pg_nodes are up and Patroni is bootstrapping)
  depends_on = [docker_container.pgbouncer]
}

# ── Init container: db migrate + admin user ───────────────────────────────────
# One-shot container. Depends on Liquibase (which creates the airflow DB + user).
# Uses airflow-entrypoint.sh which runs: airflow db migrate && airflow users create ...

resource "docker_container" "airflow_init" {
  count    = var.airflow_enabled ? 1 : 0
  name     = "airflow-init"
  image    = docker_image.airflow_custom[0].image_id
  restart  = "no"
  rm       = false
  must_run = false

  env = concat(local.airflow_common_env, [
    "AIRFLOW_ADMIN_USER=${var.airflow_admin_user}",
    "AIRFLOW_ADMIN_PASSWORD=${local.airflow_admin_password}",
    "AIRFLOW_ADMIN_EMAIL=admin@airflow.local",
  ])

  # Run the init entrypoint: db migrate + create admin user
  entrypoint = ["/bin/bash", "/opt/airflow/airflow-entrypoint.sh", "init"]

  mounts {
    target    = "/opt/airflow/dags"
    source    = abspath("${path.cwd}/dags")
    type      = "bind"
    read_only = false
  }

  mounts {
    target    = "/opt/airflow/airflow-entrypoint.sh"
    source    = abspath("${path.module}/airflow-entrypoint.sh")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name    = docker_network.pg_ha_network.name
    aliases = ["airflow-init"]
  }

  memory      = var.airflow_memory_mb
  memory_swap = var.airflow_memory_mb

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  # airflow_db_setup creates the airflow DB + user; airflow_init then runs db migrate
  depends_on = [null_resource.airflow_db_setup, docker_image.airflow_custom]
}

# ── Webserver ─────────────────────────────────────────────────────────────────

resource "docker_container" "airflow_webserver" {
  count   = var.airflow_enabled ? 1 : 0
  name    = "airflow-webserver"
  image   = docker_image.airflow_custom[0].image_id
  restart = "unless-stopped"

  env = local.airflow_common_env

  entrypoint = ["/bin/bash", "/opt/airflow/airflow-entrypoint.sh", "webserver"]

  ports {
    internal = 8080
    external = var.airflow_port
  }

  mounts {
    target    = "/opt/airflow/dags"
    source    = abspath("${path.cwd}/dags")
    type      = "bind"
    read_only = false
  }

  mounts {
    target    = "/opt/airflow/airflow-entrypoint.sh"
    source    = abspath("${path.module}/airflow-entrypoint.sh")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name    = docker_network.pg_ha_network.name
    aliases = ["airflow-webserver"]
  }

  healthcheck {
    test         = ["CMD", "curl", "-f", "http://localhost:8080/health"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "60s"
  }

  memory      = var.airflow_memory_mb
  memory_swap = var.airflow_memory_mb

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  depends_on = [docker_container.airflow_init]
}

# ── Scheduler ─────────────────────────────────────────────────────────────────

resource "docker_container" "airflow_scheduler" {
  count   = var.airflow_enabled ? 1 : 0
  name    = "airflow-scheduler"
  image   = docker_image.airflow_custom[0].image_id
  restart = "unless-stopped"

  env = local.airflow_common_env

  entrypoint = ["/bin/bash", "/opt/airflow/airflow-entrypoint.sh", "scheduler"]

  mounts {
    target    = "/opt/airflow/dags"
    source    = abspath("${path.cwd}/dags")
    type      = "bind"
    read_only = false
  }

  mounts {
    target    = "/opt/airflow/airflow-entrypoint.sh"
    source    = abspath("${path.module}/airflow-entrypoint.sh")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name    = docker_network.pg_ha_network.name
    aliases = ["airflow-scheduler"]
  }

  memory      = var.airflow_memory_mb
  memory_swap = var.airflow_memory_mb

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  depends_on = [docker_container.airflow_init]
}
