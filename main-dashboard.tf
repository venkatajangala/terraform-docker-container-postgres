# ============================================================================
# Local Status Dashboard — lightweight nginx + static HTML
# ============================================================================
# Serves a self-refreshing cluster dashboard at http://localhost:<dashboard_port>
# that proxies the Patroni REST API, etcd, Vault, and Datadog health endpoints
# through nginx so the browser never hits cross-origin CORS restrictions.
#
# Toggle with var.dashboard_enabled = true in ha-test.tfvars.
# ============================================================================

resource "docker_image" "dashboard" {
  count = var.dashboard_enabled ? 1 : 0
  name  = "nginx:alpine"
}

# Render nginx.conf — injects vault_port so the proxy rule has the right port.
resource "local_file" "dashboard_nginx_conf" {
  count = var.dashboard_enabled ? 1 : 0

  content = templatefile("${path.module}/dashboard/nginx.conf.tpl", {
    vault_port = var.vault_port
  })

  filename        = "${path.module}/dashboard/rendered/nginx.conf"
  file_permission = "0644"
}

resource "docker_container" "dashboard" {
  count = var.dashboard_enabled ? 1 : 0

  name    = "pg-dashboard"
  image   = docker_image.dashboard[0].image_id
  restart = "unless-stopped"

  ports {
    internal = 80
    external = var.dashboard_port
    protocol = "tcp"
  }

  # Static HTML dashboard
  mounts {
    target    = "/usr/share/nginx/html/index.html"
    source    = abspath("${path.module}/dashboard/index.html")
    type      = "bind"
    read_only = true
  }

  # Rendered nginx config with proxy rules
  mounts {
    target    = "/etc/nginx/conf.d/default.conf"
    source    = abspath(local_file.dashboard_nginx_conf[0].filename)
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  memory      = 64
  memory_swap = 64

  log_driver = "json-file"
  log_opts = {
    "max-size" = "5m"
    "max-file" = "2"
  }

  stop_signal  = "SIGTERM"
  stop_timeout = 5

  depends_on = [docker_container.pg_node]
}
