terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

# Create a custom bridge network for Postgres and DBHub communication
resource "docker_network" "mcp_network" {
  name   = "mcp-network"
  driver = "bridge"
}

resource "docker_image" "postgres" {
  name = "postgres:18.1-alpine"
}

resource "docker_image" "dbhub" {
  name = "bytebase/bytebase:latest"
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
  ]

  mounts {
    target = "/var/lib/postgresql/data"
    source = docker_volume.pgdata.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.mcp_network.name
  }
}

# DBHub container on the same network, connected to Postgres
resource "docker_container" "dbhub" {
  name    = "dbhub"
  image   = docker_image.dbhub.image_id
  restart = "unless-stopped"

  ports {
    internal = 8080
    external = var.dbhub_port
  }

  env = [
    "BYTEBASE_POSTGRES_URL=postgres://${var.postgres_user}:${var.postgres_password}@my-postgres:5432/${var.postgres_db}?sslmode=disable"
  ]

  networks_advanced {
    name = docker_network.mcp_network.name
  }

  depends_on = [
    docker_container.postgres
  ]
}
