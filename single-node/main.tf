terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

# Custom bridge network for Postgres (reserved for future MCP / AI agent components)
resource "docker_network" "mcp_network" {
  name   = "mcp-network"
  driver = "bridge"
}

resource "docker_image" "postgres" {
  name         = "pgvector/pgvector:0.8.2-pg18-trixie"
  keep_locally = false
}

resource "docker_volume" "pgdata" {
  name = "pgdata"
}

# PostgreSQL container on the custom network
resource "docker_container" "postgres" {
  name    = "my-postgres"
  image   = docker_image.postgres.image_id
  restart = "unless-stopped"

  ports {
    internal = 5432
    external = 5432
  }

  env = [
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
    "POSTGRES_INITDB_ARGS=-c shared_preload_libraries=vector"
  ]

  mounts {
    target = "/var/lib/postgresql"
    source = docker_volume.pgdata.name
    type   = "volume"
  }

  mounts {
    target    = "/docker-entrypoint-initdb.d/init-pgvector.sql"
    source    = abspath("${path.module}/init-pgvector.sql")
    type      = "bind"
    read_only = true
  }

  networks_advanced {
    name = docker_network.mcp_network.name
  }
}
