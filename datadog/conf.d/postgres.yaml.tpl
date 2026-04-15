## Datadog PostgreSQL integration — rendered by Terraform (passwords injected at plan time)
## Monitors all three Patroni cluster nodes directly over the pg-ha-network Docker bridge.
## Uses the postgres superuser; for production, create a dedicated datadog user with pg_monitor role.

init_config:

instances:
  ## ─── pg-node-1 (initial primary) ──────────────────────────────────────────
  - host: pg-node-1
    port: 5432
    username: ${postgres_user}
    password: "${postgres_password}"
    dbname: ${postgres_db}
    tags:
      - "node:pg-node-1"
      - "role:primary"
      - "cluster:pg-ha-cluster"
    collect_activity_metrics: true
    collect_count_metrics: true
    collect_database_size_metrics: true
    collect_bloat_metrics: false
    collect_default_database: true
    ## Track replication lag reported from this node's pg_stat_replication view
    ## (only populated when this node is primary)
    relations:
      - relation_regex: ".*"
        schemas:
          - public
          - audit

  ## ─── pg-node-2 (replica) ───────────────────────────────────────────────────
  - host: pg-node-2
    port: 5432
    username: ${postgres_user}
    password: "${postgres_password}"
    dbname: ${postgres_db}
    tags:
      - "node:pg-node-2"
      - "role:replica"
      - "cluster:pg-ha-cluster"
    collect_activity_metrics: true
    collect_count_metrics: false
    collect_database_size_metrics: true
    collect_bloat_metrics: false

  ## ─── pg-node-3 (replica) ───────────────────────────────────────────────────
  - host: pg-node-3
    port: 5432
    username: ${postgres_user}
    password: "${postgres_password}"
    dbname: ${postgres_db}
    tags:
      - "node:pg-node-3"
      - "role:replica"
      - "cluster:pg-ha-cluster"
    collect_activity_metrics: true
    collect_count_metrics: false
    collect_database_size_metrics: true
    collect_bloat_metrics: false
