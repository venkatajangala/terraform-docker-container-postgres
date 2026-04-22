# ============================================================================
# Prometheus + Grafana Monitoring Stack
# ============================================================================
# Toggle with var.monitoring_enabled = true in ha-test.tfvars.
#
# Containers:
#   • postgres-exporter-{1,2,3}  — one per Patroni node (port 9187, internal)
#   • pgbouncer-exporter-{1..N}  — one per PgBouncer instance (port 9127, internal)
#   • prometheus                  — scrapes all exporters (host port var.prometheus_port)
#   • grafana                     — dashboards (host port var.grafana_port)
#
# Grafana:  http://localhost:<grafana_port>    admin / <grafana_admin_password>
# Prometheus: http://localhost:<prometheus_port>
# ============================================================================

# ── Images ───────────────────────────────────────────────────────────────────

resource "docker_image" "prometheus" {
  count = var.monitoring_enabled ? 1 : 0
  name  = "prom/prometheus:v2.55.1"
}

resource "docker_image" "postgres_exporter" {
  count = var.monitoring_enabled ? 1 : 0
  name  = "prometheuscommunity/postgres-exporter:v0.19.1"
}

resource "docker_image" "pgbouncer_exporter" {
  count = (var.monitoring_enabled && var.pgbouncer_enabled) ? 1 : 0
  name  = "prometheuscommunity/pgbouncer-exporter:v0.9.0"
}

resource "docker_image" "grafana" {
  count = var.monitoring_enabled ? 1 : 0
  name  = "grafana/grafana:11.6.0"
}

# ── Persistent volumes ───────────────────────────────────────────────────────

resource "docker_volume" "prometheus_data" {
  count = var.monitoring_enabled ? 1 : 0
  name  = "prometheus-data"
}

resource "docker_volume" "grafana_data" {
  count = var.monitoring_enabled ? 1 : 0
  name  = "grafana-data"
}

# ── Render Prometheus scrape config (dynamic pgbouncer target list) ──────────

resource "local_file" "prometheus_conf" {
  count = var.monitoring_enabled ? 1 : 0

  content = templatefile("${path.module}/monitoring/prometheus/prometheus.yml.tpl", {
    pgbouncer_enabled  = var.pgbouncer_enabled
    pgbouncer_replicas = var.pgbouncer_replicas
  })

  filename        = "${path.module}/monitoring/rendered/prometheus.yml"
  file_permission = "0644"
}

# ── postgres_exporter — one per Patroni node ─────────────────────────────────
# Connects directly to each pg-node-N:5432 (bypasses PgBouncer) for accurate
# per-node metrics including replication info on the primary.

resource "docker_container" "postgres_exporter" {
  count = var.monitoring_enabled ? 3 : 0

  name    = "postgres-exporter-${count.index + 1}"
  image   = docker_image.postgres_exporter[0].image_id
  restart = "unless-stopped"

  env = [
    "DATA_SOURCE_NAME=postgresql://postgres:${local.postgres_password}@pg-node-${count.index + 1}:5432/postgres?sslmode=disable",
    "PG_EXPORTER_AUTO_DISCOVER_DATABASES=true",
  ]

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  memory      = 64
  memory_swap = 64

  log_driver = "json-file"
  log_opts   = { "max-size" = "5m", "max-file" = "2" }

  depends_on = [docker_container.pg_node]
}

# ── pgbouncer_exporter — one per PgBouncer instance ──────────────────────────
# pgadmin is in stats_users in pgbouncer.ini so it can run SHOW STATS/POOLS.

resource "docker_container" "pgbouncer_exporter" {
  count = (var.monitoring_enabled && var.pgbouncer_enabled) ? var.pgbouncer_replicas : 0

  name    = "pgbouncer-exporter-${count.index + 1}"
  image   = docker_image.pgbouncer_exporter[0].image_id
  restart = "unless-stopped"

  # The pgbouncer_exporter image uses a CLI flag, not DATA_SOURCE_NAME.
  command = [
    "--pgBouncer.connectionString=postgresql://pgadmin:${local.postgres_password}@pgbouncer-${count.index + 1}:6432/pgbouncer?sslmode=disable",
  ]

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  memory      = 64
  memory_swap = 64

  log_driver = "json-file"
  log_opts   = { "max-size" = "5m", "max-file" = "2" }

  depends_on = [docker_container.pgbouncer]
}

# ── Prometheus ────────────────────────────────────────────────────────────────

resource "docker_container" "prometheus" {
  count = var.monitoring_enabled ? 1 : 0

  name    = "prometheus"
  image   = docker_image.prometheus[0].image_id
  restart = "unless-stopped"

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--storage.tsdb.retention.time=15d",
    "--web.enable-lifecycle",
    "--web.console.libraries=/usr/share/prometheus/console_libraries",
    "--web.console.templates=/usr/share/prometheus/consoles",
  ]

  ports {
    internal = 9090
    external = var.prometheus_port
    protocol = "tcp"
  }

  mounts {
    target    = "/etc/prometheus/prometheus.yml"
    source    = abspath(local_file.prometheus_conf[0].filename)
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/prometheus"
    source = docker_volume.prometheus_data[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  memory      = 256
  memory_swap = 256

  log_driver = "json-file"
  log_opts   = { "max-size" = "10m", "max-file" = "3" }

  stop_signal  = "SIGTERM"
  stop_timeout = 30

  depends_on = [docker_container.postgres_exporter, docker_container.pgbouncer_exporter]
}

# ── Grafana ───────────────────────────────────────────────────────────────────

resource "docker_container" "grafana" {
  count = var.monitoring_enabled ? 1 : 0

  name    = "grafana"
  image   = docker_image.grafana[0].image_id
  restart = "unless-stopped"

  env = [
    "GF_SECURITY_ADMIN_USER=admin",
    "GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}",
    "GF_USERS_ALLOW_SIGN_UP=false",
    # Allow anonymous read-only access — convenient for local dev
    "GF_AUTH_ANONYMOUS_ENABLED=true",
    "GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer",
    # Silence the "install plugins" nag
    "GF_ANALYTICS_REPORTING_ENABLED=false",
    "GF_ANALYTICS_CHECK_FOR_UPDATES=false",
  ]

  ports {
    internal = 3000
    external = var.grafana_port
    protocol = "tcp"
  }

  mounts {
    target = "/var/lib/grafana"
    source = docker_volume.grafana_data[0].name
    type   = "volume"
  }

  # Provisioning directory: datasources + dashboard provider + dashboard JSONs
  mounts {
    target    = "/etc/grafana/provisioning"
    source    = abspath("${path.module}/monitoring/grafana/provisioning")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  memory      = 256
  memory_swap = 256

  log_driver = "json-file"
  log_opts   = { "max-size" = "10m", "max-file" = "3" }

  stop_signal  = "SIGTERM"
  stop_timeout = 30

  depends_on = [docker_container.prometheus]
}
