# ============================================================================
# Datadog Agent — Monitoring & Observability
# ============================================================================
# Toggle with var.datadog_enabled = true in ha-test.tfvars.
# Requires a valid Datadog API key (var.datadog_api_key / TF_VAR_datadog_api_key).
#
# Integrations enabled:
#   • postgres  — connects directly to all three Patroni nodes (pg-ha-network)
#   • pgbouncer — connects to each pgbouncer admin console
#   • http_check — Patroni /liveness, /cluster, etcd /health, Vault /v1/sys/health
#   • docker    — automatic container metrics via /var/run/docker.sock
#   • process   — host-level process metrics via /host/proc
# ============================================================================

# ── Datadog Agent image ──────────────────────────────────────────────────────

resource "docker_image" "datadog_agent" {
  count = var.datadog_enabled ? 1 : 0
  name  = "datadog/agent:7.78.0"
}

# ── Persistent volume for agent state (check results, forwarder queue) ───────

resource "docker_volume" "datadog_data" {
  count = var.datadog_enabled ? 1 : 0
  name  = "datadog-data"
}

# ── Render PostgreSQL integration config (password injected at plan time) ────

resource "local_file" "datadog_postgres_conf" {
  count = var.datadog_enabled ? 1 : 0

  content = templatefile("${path.module}/datadog/conf.d/postgres.yaml.tpl", {
    postgres_user     = "postgres"
    postgres_password = local.postgres_password
    postgres_db       = var.postgres_db
  })

  filename        = "${path.module}/datadog/rendered/postgres.yaml"
  file_permission = "0600"
}

# ── Render PgBouncer integration config ─────────────────────────────────────

resource "local_file" "datadog_pgbouncer_conf" {
  count = var.datadog_enabled ? 1 : 0

  content = templatefile("${path.module}/datadog/conf.d/pgbouncer.yaml.tpl", {
    pgbouncer_user     = var.postgres_user
    pgbouncer_password = local.postgres_password
    pgbouncer_replicas = [for i in range(1, var.pgbouncer_replicas + 1) : tostring(i)]
  })

  filename        = "${path.module}/datadog/rendered/pgbouncer.yaml"
  file_permission = "0600"
}

# ── Render HTTP check config (Patroni + etcd + optional Vault) ───────────────

resource "local_file" "datadog_http_check_conf" {
  count = var.datadog_enabled ? 1 : 0

  content = templatefile("${path.module}/datadog/conf.d/http_check.yaml.tpl", {
    vault_enabled = var.vault_enabled
    vault_port    = var.vault_port
  })

  filename        = "${path.module}/datadog/rendered/http_check.yaml"
  file_permission = "0644"
}

# ── Datadog Agent container ──────────────────────────────────────────────────

resource "docker_container" "datadog_agent" {
  count = var.datadog_enabled ? 1 : 0

  name    = "datadog-agent"
  image   = docker_image.datadog_agent[0].image_id
  restart = "unless-stopped"

  env = [
    "DD_API_KEY=${var.datadog_api_key}",
    "DD_SITE=${var.datadog_site}",

    # Identify this agent in the Datadog UI
    "DD_HOSTNAME=pg-ha-cluster",
    "DD_TAGS=env:${var.vault_environment} cluster:pg-ha-cluster stack:patroni",

    # Log collection — gather stdout/stderr from all containers
    "DD_LOGS_ENABLED=true",
    "DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL=true",
    "DD_LOGS_CONFIG_DOCKER_CONTAINER_USE_FILE=true",

    # Process agent for container-level CPU/mem metrics
    "DD_PROCESS_AGENT_ENABLED=true",

    # Exclude the agent's own container from self-monitoring
    "DD_CONTAINER_EXCLUDE=name:datadog-agent",

    # DogStatsD — allow custom metrics from other containers on the same network
    "DD_DOGSTATSD_NON_LOCAL_TRAFFIC=true",

    # Disable APM and Kubernetes event collection (not needed in pure Docker)
    "DD_APM_ENABLED=false",
    "DD_COLLECT_KUBERNETES_EVENTS=false",

    # Expose a lightweight HTTP health endpoint (process-level liveness only).
    # The image default healthcheck uses `agent health` which marks the
    # forwarder unhealthy when the API key is invalid — this overrides that
    # with a simple 200 OK endpoint that reflects agent process liveness.
    "DD_HEALTH_PORT=5555",
  ]

  # Override the image's default `agent health` healthcheck with a lightweight
  # HTTP probe on DD_HEALTH_PORT=5555.  This avoids false UNHEALTHY status when
  # the forwarder can't reach datadoghq.com (e.g. invalid / test API key).
  healthcheck {
    test         = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5555 || exit 1"]
    interval     = "30s"
    timeout      = "5s"
    start_period = "60s"
    retries      = 3
  }

  # DogStatsD port — exposes to host so apps can push custom metrics
  ports {
    internal = 8125
    external = var.datadog_statsd_port
    protocol = "udp"
  }

  # ── Volume mounts ────────────────────────────────────────────────────────

  # Docker socket — container discovery, live container metrics, log collection
  mounts {
    target    = "/var/run/docker.sock"
    source    = "/var/run/docker.sock"
    type      = "bind"
    read_only = true
  }

  # Host /proc — process-level CPU/mem/IO metrics
  mounts {
    target    = "/host/proc"
    source    = "/proc"
    type      = "bind"
    read_only = true
  }

  # cgroup filesystem — container resource accounting
  mounts {
    target    = "/host/sys/fs/cgroup"
    source    = "/sys/fs/cgroup"
    type      = "bind"
    read_only = true
  }

  # Persistent agent state (forwarder queue, check results)
  mounts {
    target = "/opt/datadog-agent/run"
    source = docker_volume.datadog_data[0].name
    type   = "volume"
  }

  # PostgreSQL integration config (rendered with passwords by local_file above)
  mounts {
    target    = "/etc/datadog-agent/conf.d/postgres.d/conf.yaml"
    source    = abspath(local_file.datadog_postgres_conf[0].filename)
    type      = "bind"
    read_only = true
  }

  # PgBouncer integration config — only mount when pooling is enabled
  dynamic "mounts" {
    for_each = var.pgbouncer_enabled ? [1] : []
    content {
      target    = "/etc/datadog-agent/conf.d/pgbouncer.d/conf.yaml"
      source    = abspath(local_file.datadog_pgbouncer_conf[0].filename)
      type      = "bind"
      read_only = true
    }
  }

  # HTTP checks for Patroni REST API, etcd, and Vault
  mounts {
    target    = "/etc/datadog-agent/conf.d/http_check.d/conf.yaml"
    source    = abspath(local_file.datadog_http_check_conf[0].filename)
    type      = "bind"
    read_only = true
  }

  # ── Networking ────────────────────────────────────────────────────────────

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  # ── Resource limits ───────────────────────────────────────────────────────

  memory      = var.datadog_memory_mb
  memory_swap = var.datadog_memory_mb

  # ── Logging ───────────────────────────────────────────────────────────────

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  stop_signal  = "SIGTERM"
  stop_timeout = 30

  # Start after PostgreSQL nodes and PgBouncer are up so the first
  # check cycle finds live endpoints rather than logging connection errors.
  depends_on = [docker_container.pg_node, docker_container.pgbouncer]
}
