# ============================================================================
# Apache Airflow ETL Platform
# Enabled via: airflow_enabled = true in ha-test.tfvars
#
# Dependency chain:
#   pg_nodes → pgbouncer → null_resource.airflow_db_setup (creates airflow DB + user)
#            → docker_container.liquibase (records 05-grant-airflow-connect changeset)
#            → airflow_init (db migrate + admin user)
#            → airflow_webserver / airflow_scheduler
#
# Connection strategy (both URLs are set dynamically by airflow-entrypoint.sh):
#   AIRFLOW__DATABASE__SQL_ALCHEMY_CONN — airflow_user → airflow DB → Patroni primary
#   AIRFLOW_CONN_POSTGRES_HA            — pgadmin      → postgres DB → Patroni primary
#
#   The entrypoint polls pg-node-{1,2,3}:8008/leader (Patroni REST API via internal
#   Docker DNS) to find the current primary, then builds both URLs pointing to that
#   node at port 5432. This guarantees writes never land on a read-only replica even
#   after a Patroni failover, without any manual PgBouncer reconfiguration.
#
#   AIRFLOW_CONN_PGBOUNCER_ADMIN — pgadmin → pgbouncer virtual DB → admin console
#   Used by the health-check DAG for SHOW POOLS (only works via admin console).
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

  # Shared env vars for all Airflow containers.
  # AIRFLOW__DATABASE__SQL_ALCHEMY_CONN and AIRFLOW_CONN_POSTGRES_HA are NOT
  # set statically — airflow-entrypoint.sh discovers the Patroni primary at
  # runtime and builds both URLs pointing directly to that node.
  airflow_common_env = var.airflow_enabled ? [
    # Credentials for airflow-entrypoint.sh to build both DB URLs dynamically
    "AIRFLOW_DB_USER=airflow_user",
    "AIRFLOW_DB_PASSWORD=${local.airflow_db_password}",
    "AIRFLOW_DB_NAME=airflow",
    # pgadmin password — entrypoint rebuilds AIRFLOW_CONN_POSTGRES_HA after
    # discovering the primary so ETL write tasks never land on a replica.
    "PGADMIN_PASSWORD=${local.postgres_password}",
    "AIRFLOW__CORE__EXECUTOR=LocalExecutor",
    "AIRFLOW__CORE__FERNET_KEY=${local.airflow_fernet_key}",
    "AIRFLOW__CORE__LOAD_EXAMPLES=False",
    "AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION=True",
    "AIRFLOW__WEBSERVER__BASE_URL=http://localhost:${var.airflow_port}",
    "AIRFLOW__WEBSERVER__EXPOSE_CONFIG=True",
    # PgBouncer admin console — used by the health-check DAG for SHOW POOLS.
    # Connects to the 'pgbouncer' virtual database (not a real PostgreSQL DB).
    "AIRFLOW_CONN_PGBOUNCER_ADMIN=postgresql://pgadmin:${local.postgres_password}@pgbouncer-1:6432/pgbouncer",
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
