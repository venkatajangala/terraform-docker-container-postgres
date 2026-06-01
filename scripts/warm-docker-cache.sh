#!/usr/bin/env bash
# Pre-pull every external base image referenced by the stack so the first
# `terraform apply` after a fresh Docker install skips ~5 min of serial
# registry round-trips. Safe to re-run — `docker pull` no-ops on cache hits.
#
# Usage:  bash scripts/warm-docker-cache.sh
set -euo pipefail

IMAGES=(
  # PostgreSQL HA core
  pgvector/pgvector:0.8.2-pg18-trixie
  quay.io/coreos/etcd:v3.5.29
  alpine:3.21
  liquibase/liquibase:5.0.2

  # Secrets
  hashicorp/vault:1.21.2

  # Monitoring stack
  prom/prometheus:v2.55.1
  grafana/grafana:11.6.0
  prometheuscommunity/postgres-exporter:v0.19.1
  prometheuscommunity/pgbouncer-exporter:v0.9.0
  nginx:1.30.0-alpine

  # Optional integrations
  apache/airflow:2.10.2-python3.12
  datadog/agent:7.78.0
)

echo "Warming Docker image cache (${#IMAGES[@]} images, parallel)…"
pids=()
for img in "${IMAGES[@]}"; do
  ( docker pull --quiet "$img" >/dev/null && echo "  ✓ $img" \
                                          || echo "  ✗ $img (pull failed)" ) &
  pids+=($!)
done

for pid in "${pids[@]}"; do wait "$pid" || true; done
echo "Done. Run: terraform apply -var-file=ha-test.tfvars -auto-approve"
