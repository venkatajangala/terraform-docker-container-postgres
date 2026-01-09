terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

resource "docker_image" "postgres" {
  name = "postgres:18.1-alpine"
}

resource "docker_volume" "pgdata" {
  name = "pgdata"
}

resource "docker_container" "postgres" {
  name    = "postgres-tf"
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
}
