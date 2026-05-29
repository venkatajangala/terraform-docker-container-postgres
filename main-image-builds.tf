# ============================================================================
# Local Image Builds (buildx CLI, out-of-band)
# ============================================================================
#
# WHY THIS EXISTS
# ---------------
# The kreuzwerker/docker provider's in-process `build {}` block is broken
# against Docker Engine 28+/Docker Desktop 4.7x:
#   * Legacy builder (build.version = "1", the default) fails intermittently
#     with "archive/tar: invalid tar header" / "invalid deflate data" — the
#     provider's own tar/gzip context streaming is incompatible with the newer
#     daemon's BuildKit-only endpoints.
#   * BuildKit (build.version = "2") hangs indefinitely (>4 min for a 6-second
#     image) — the provider's buildkit session handshake does not complete.
#
# The Docker CLI's own `buildx build` builds the SAME Dockerfiles cleanly in
# seconds, so we delegate all local image builds to it via `terraform_data`
# + `local-exec`. The `docker_image` resources below then simply *reference*
# the resulting local tags (no `build {}` block), keeping every existing
# `docker_image.<x>.image_id` reference in the rest of the config valid.
#
# Rebuilds are triggered by `triggers_replace` on the Dockerfile and every
# file it COPYs, so editing any of them forces a fresh buildx run.
# ============================================================================

resource "terraform_data" "build_postgres_patroni" {
  triggers_replace = [
    filemd5("${path.module}/Dockerfile.patroni"),
    filemd5("${path.module}/initdb-wrapper.sh"),
    filemd5("${path.module}/entrypoint-patroni.sh"),
    filemd5("${path.module}/vault-secrets.sh"),
  ]

  provisioner "local-exec" {
    working_dir = path.module
    command     = "docker buildx build --load -t postgres-patroni:18-pgvector -f Dockerfile.patroni ."
  }
}

resource "terraform_data" "build_pgbouncer" {
  count = var.pgbouncer_enabled ? 1 : 0

  triggers_replace = [
    filemd5("${path.module}/Dockerfile.pgbouncer"),
    filemd5("${path.module}/entrypoint-pgbouncer.sh"),
    filemd5("${path.module}/vault-secrets.sh"),
  ]

  provisioner "local-exec" {
    working_dir = path.module
    command     = "docker buildx build --load -t pgbouncer:ha -f Dockerfile.pgbouncer ."
  }
}

resource "terraform_data" "build_liquibase" {
  count = var.liquibase_enabled ? 1 : 0

  triggers_replace = [
    filemd5("${path.module}/Dockerfile.liquibase"),
    filemd5("${path.module}/liquibase-entrypoint.sh"),
    filemd5("${path.module}/vault-secrets.sh"),
  ]

  provisioner "local-exec" {
    working_dir = path.module
    command     = "docker buildx build --load -t liquibase:ha -f Dockerfile.liquibase ."
  }
}

resource "terraform_data" "build_airflow_custom" {
  count = var.airflow_enabled ? 1 : 0

  triggers_replace = [
    filemd5("${path.module}/Dockerfile.airflow"),
  ]

  provisioner "local-exec" {
    working_dir = path.module
    command     = "docker buildx build --load -t custom-airflow-etl:latest -f Dockerfile.airflow ."
  }
}
