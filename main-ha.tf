terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

# ============================================================================
# HA PostgreSQL Cluster with Patroni + etcd
# ============================================================================

# Create a custom bridge network for HA cluster communication
resource "docker_network" "pg_ha_network" {
  name   = "pg-ha-network"
  driver = "bridge"
}

# ============================================================================
# ETCD - Distributed Configuration Store (DCS)
# ============================================================================

resource "docker_image" "etcd" {
  name = "quay.io/coreos/etcd:v3.5.0"
}

resource "docker_volume" "etcd_data" {
  name = "etcd-data"
}

resource "docker_container" "etcd" {
  name    = "etcd"
  image   = docker_image.etcd.image_id
  restart = "unless-stopped"

  env = [
    "ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379",
    "ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379",
    "ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380",
    "ETCD_INITIAL_ADVERTISE_PEER_URLS=http://etcd:2380",
    "ETCD_INITIAL_CLUSTER=etcd=http://etcd:2380",
    "ETCD_CLUSTER_STATE=new",
    "ETCD_NAME=etcd"
  ]

  ports {
    internal = 2379
    external = var.etcd_port
  }

  ports {
    internal = 2380
    external = var.etcd_peer_port
  }

  mounts {
    target = "/etcd-data"
    source = docker_volume.etcd_data.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }
}

# ============================================================================
# PostgreSQL Custom Image Build (Patroni + pgvector)
# ============================================================================

resource "docker_image" "postgres_patroni" {
  name = "postgres-patroni:18-pgvector"
  build {
    context    = path.module
    dockerfile = "Dockerfile.patroni"
  }
}

# ============================================================================
# Shared Volumes for PostgreSQL HA Cluster
# ============================================================================

resource "docker_volume" "pgbackrest_repo" {
  name = "pgbackrest-repo"
}

resource "docker_volume" "pg_node_1_data" {
  name = "pg-node-1-data"
}

resource "docker_volume" "pg_node_2_data" {
  name = "pg-node-2-data"
}

resource "docker_volume" "pg_node_3_data" {
  name = "pg-node-3-data"
}

# ============================================================================
# PostgreSQL Node 1 (Primary/Replica with Patroni)
# ============================================================================

resource "docker_container" "pg_node_1" {
  name    = "pg-node-1"
  image   = docker_image.postgres_patroni.image_id
  restart = "unless-stopped"

  env = concat([
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
    "REPLICATION_PASSWORD=${var.replication_password}",
    "PATRONI_SCOPE=pg-ha-cluster",
    "PATRONI_NAME=pg-node-1",
    "PATRONI_RESTAPI__LISTEN=0.0.0.0:8008",
    "PATRONI_RESTAPI__CONNECT_ADDRESS=pg-node-1:8008",
    "PATRONI_POSTGRESQL__LISTEN=0.0.0.0:5432",
    "PATRONI_POSTGRESQL__CONNECT_ADDRESS=pg-node-1:5432",
    "PATRONI_POSTGRESQL__DATA_DIR=/var/lib/postgresql/18/main",
    "PATRONI_POSTGRESQL__PARAMETERS__SHARED_PRELOAD_LIBRARIES=vector,pg_stat_statements",
    "PATRONI_POSTGRESQL__PGCTLCLUSTER=18-main",
    "PATRONI_POSTGRESQL__INITDB__ENCODING=UTF8",
    "PATRONI_POSTGRESQL__INITDB__LOCALE=en_US.UTF-8",
    "PATRONI_POSTGRESQL__REMOVE_DATA_DIRECTORY_ON_DIVERGENCE=true",
    "PATRONI_DCS_TYPE=etcd3",
    "PATRONI_ETCD__HOSTS=etcd:2379",
    "PATRONI_ETCD__PROTOCOL=http"
  ], var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}"
  ] : [])

  ports {
    internal = 5432
    external = 5432
  }

  ports {
    internal = 8008
    external = 8008
  }

  mounts {
    target = "/var/lib/postgresql"
    source = docker_volume.pg_node_1_data.name
    type   = "volume"
  }

  mounts {
    target    = "/etc/patroni/patroni.yml"
    source    = abspath("${path.module}/patroni/patroni-node-1.yml")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/lib/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  mounts {
    target = "/var/log/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [docker_container.etcd]
}

# ============================================================================
# PostgreSQL Node 2 (Replica with Patroni)
# ============================================================================

resource "docker_container" "pg_node_2" {
  name    = "pg-node-2"
  image   = docker_image.postgres_patroni.image_id
  restart = "unless-stopped"

  env = concat([
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
    "REPLICATION_PASSWORD=${var.replication_password}",
    "PATRONI_SCOPE=pg-ha-cluster",
    "PATRONI_NAME=pg-node-2",
    "PATRONI_RESTAPI__LISTEN=0.0.0.0:8008",
    "PATRONI_RESTAPI__CONNECT_ADDRESS=pg-node-2:8008",
    "PATRONI_POSTGRESQL__LISTEN=0.0.0.0:5432",
    "PATRONI_POSTGRESQL__CONNECT_ADDRESS=pg-node-2:5432",
    "PATRONI_POSTGRESQL__DATA_DIR=/var/lib/postgresql/18/main",
    "PATRONI_POSTGRESQL__PARAMETERS__SHARED_PRELOAD_LIBRARIES=vector,pg_stat_statements",
    "PATRONI_POSTGRESQL__PGCTLCLUSTER=18-main",
    "PATRONI_POSTGRESQL__INITDB__ENCODING=UTF8",
    "PATRONI_POSTGRESQL__INITDB__LOCALE=en_US.UTF-8",
    "PATRONI_POSTGRESQL__REMOVE_DATA_DIRECTORY_ON_DIVERGENCE=true",
    "PATRONI_DCS_TYPE=etcd3",
    "PATRONI_ETCD__HOSTS=etcd:2379",
    "PATRONI_ETCD__PROTOCOL=http"
  ], var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}"
  ] : [])

  ports {
    internal = 5432
    external = 5433
  }

  ports {
    internal = 8008
    external = 8009
  }

  mounts {
    target = "/var/lib/postgresql"
    source = docker_volume.pg_node_2_data.name
    type   = "volume"
  }

  mounts {
    target    = "/etc/patroni/patroni.yml"
    source    = abspath("${path.module}/patroni/patroni-node-2.yml")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/lib/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  mounts {
    target = "/var/log/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [docker_container.etcd, docker_container.pg_node_1]
}

# ============================================================================
# PostgreSQL Node 3 (Replica with Patroni)
# ============================================================================


resource "docker_container" "pg_node_3" {
  name    = "pg-node-3"
  image   = docker_image.postgres_patroni.image_id
  restart = "unless-stopped"

  env = concat([
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
    "REPLICATION_PASSWORD=${var.replication_password}",
    "PATRONI_SCOPE=pg-ha-cluster",
    "PATRONI_NAME=pg-node-3",
    "PATRONI_RESTAPI__LISTEN=0.0.0.0:8008",
    "PATRONI_RESTAPI__CONNECT_ADDRESS=pg-node-3:8008",
    "PATRONI_POSTGRESQL__LISTEN=0.0.0.0:5432",
    "PATRONI_POSTGRESQL__CONNECT_ADDRESS=pg-node-3:5432",
    "PATRONI_POSTGRESQL__DATA_DIR=/var/lib/postgresql/18/main",
    "PATRONI_POSTGRESQL__PARAMETERS__SHARED_PRELOAD_LIBRARIES=vector,pg_stat_statements",
    "PATRONI_POSTGRESQL__PGCTLCLUSTER=18-main",
    "PATRONI_POSTGRESQL__INITDB__ENCODING=UTF8",
    "PATRONI_POSTGRESQL__INITDB__LOCALE=en_US.UTF-8",
    "PATRONI_POSTGRESQL__REMOVE_DATA_DIRECTORY_ON_DIVERGENCE=true",
    "PATRONI_DCS_TYPE=etcd3",
    "PATRONI_ETCD__HOSTS=etcd:2379",
    "PATRONI_ETCD__PROTOCOL=http"
  ], var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}"
  ] : [])

  ports {
    internal = 5432
    external = 5434
  }

  ports {
    internal = 8008
    external = 8010
  }

  mounts {
    target = "/var/lib/postgresql"
    source = docker_volume.pg_node_3_data.name
    type   = "volume"
  }

  mounts {
    target    = "/etc/patroni/patroni.yml"
    source    = abspath("${path.module}/patroni/patroni-node-3.yml")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/lib/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  mounts {
    target = "/var/log/pgbackrest"
    source = docker_volume.pgbackrest_repo.name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [docker_container.etcd, docker_container.pg_node_1]
}

# ============================================================================
# DBHub (Bytebase) - Connects to Primary Node
# ============================================================================

resource "docker_image" "dbhub" {
  name = "bytebase/bytebase:latest"
}

resource "docker_container" "dbhub" {
  name    = "dbhub"
  image   = docker_image.dbhub.image_id
  restart = "unless-stopped"

  ports {
    internal = 8080
    external = var.dbhub_port
  }

  env = [
    "BYTEBASE_POSTGRES_URL=postgres://${var.postgres_user}:${var.postgres_password}@pg-node-1:5432/${var.postgres_db}?sslmode=disable"
  ]

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [
    docker_container.pg_node_1,
    docker_container.pg_node_2,
    docker_container.pg_node_3
  ]
}

# ============================================================================
# PgBouncer - Connection Pooling Layer for HA Configuration
# ============================================================================

resource "docker_image" "pgbouncer" {
  count = var.pgbouncer_enabled ? 1 : 0
  name  = "pgbouncer:ha"
  build {
    context    = path.module
    dockerfile = "Dockerfile.pgbouncer"
  }
}

resource "docker_volume" "pgbouncer_logs" {
  count = var.pgbouncer_enabled ? 1 : 0
  name  = "pgbouncer-logs"
}

# PgBouncer Instance 1
resource "docker_container" "pgbouncer_1" {
  count   = var.pgbouncer_enabled && var.pgbouncer_replicas >= 1 ? 1 : 0
  name    = "pgbouncer-1"
  image   = docker_image.pgbouncer[0].image_id
  restart = "unless-stopped"

  env = concat([
    "PGBOUNCER_CONFIG_DIR=/etc/pgbouncer",
    "PGBOUNCER_LOG_DIR=/var/log/pgbouncer",
    "PGBOUNCER_PORT=6432"
  ], var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}",
    "DB_ADMIN_USER=${var.postgres_user}",
    "DB_REPLICATION_USER=replicator"
  ] : [
    "DB_ADMIN_PASSWORD=${var.postgres_password}",
    "DB_REPLICATION_PASSWORD=${var.replication_password}"
  ])

  ports {
    internal = 6432
    external = var.pgbouncer_external_port_base
  }

  mounts {
    target    = "/etc/pgbouncer/pgbouncer.ini"
    source    = abspath("${path.module}/pgbouncer/pgbouncer.ini")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/log/pgbouncer"
    source = docker_volume.pgbouncer_logs[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [
    docker_container.pg_node_1,
    docker_container.pg_node_2,
    docker_container.pg_node_3
  ]
}

# PgBouncer Instance 2

resource "docker_container" "pgbouncer_2" {
  count   = var.pgbouncer_enabled && var.pgbouncer_replicas >= 2 ? 1 : 0
  name    = "pgbouncer-2"
  image   = docker_image.pgbouncer[0].image_id
  restart = "unless-stopped"

  env = concat([
    "PGBOUNCER_CONFIG_DIR=/etc/pgbouncer",
    "PGBOUNCER_LOG_DIR=/var/log/pgbouncer",
    "PGBOUNCER_PORT=6432"
  ], var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}",
    "DB_ADMIN_USER=${var.postgres_user}",
    "DB_REPLICATION_USER=replicator"
  ] : [
    "DB_ADMIN_PASSWORD=${var.postgres_password}",
    "DB_REPLICATION_PASSWORD=${var.replication_password}"
  ])

  ports {
    internal = 6432
    external = var.pgbouncer_external_port_base + 1
  }

  mounts {
    target    = "/etc/pgbouncer/pgbouncer.ini"
    source    = abspath("${path.module}/pgbouncer/pgbouncer.ini")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/log/pgbouncer"
    source = docker_volume.pgbouncer_logs[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [
    docker_container.pg_node_1,
    docker_container.pg_node_2,
    docker_container.pg_node_3
  ]
}

# PgBouncer Instance 3
resource "docker_container" "pgbouncer_3" {
  count   = var.pgbouncer_enabled && var.pgbouncer_replicas >= 3 ? 1 : 0
  name    = "pgbouncer-3"
  image   = docker_image.pgbouncer[0].image_id
  restart = "unless-stopped"

  env = concat([
    "PGBOUNCER_CONFIG_DIR=/etc/pgbouncer",
    "PGBOUNCER_LOG_DIR=/var/log/pgbouncer",
    "PGBOUNCER_PORT=6432"
  ], var.infisical_enabled ? [
    "INFISICAL_API_KEY=${var.infisical_api_key}",
    "INFISICAL_PROJECT_ID=${var.infisical_project_id}",
    "INFISICAL_ENVIRONMENT=${var.infisical_environment}",
    "INFISICAL_HOST=http://infisical:${var.infisical_port}",
    "DB_ADMIN_USER=${var.postgres_user}",
    "DB_REPLICATION_USER=replicator"
  ] : [
    "DB_ADMIN_PASSWORD=${var.postgres_password}",
    "DB_REPLICATION_PASSWORD=${var.replication_password}"
  ])

  ports {
    internal = 6432
    external = var.pgbouncer_external_port_base + 2
  }

  mounts {
    target    = "/etc/pgbouncer/pgbouncer.ini"
    source    = abspath("${path.module}/pgbouncer/pgbouncer.ini")
    type      = "bind"
    read_only = true
  }

  mounts {
    target = "/var/log/pgbouncer"
    source = docker_volume.pgbouncer_logs[0].name
    type   = "volume"
  }

  networks_advanced {
    name = docker_network.pg_ha_network.name
  }

  depends_on = [
    docker_container.pg_node_1,
    docker_container.pg_node_2,
    docker_container.pg_node_3
  ]
}
