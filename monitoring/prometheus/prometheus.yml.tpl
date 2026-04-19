global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    cluster: pg-ha

scrape_configs:

  - job_name: prometheus
    static_configs:
      - targets: [localhost:9090]

  # postgres_exporter — one container per Patroni node
  # The 'node' label is added via relabeling so dashboards can filter by pg-node-N.
  - job_name: postgres
    static_configs:
      - targets:
          - postgres-exporter-1:9187
          - postgres-exporter-2:9187
          - postgres-exporter-3:9187
    relabel_configs:
      - source_labels: [__address__]
        regex: 'postgres-exporter-(\d+):.*'
        target_label: node
        replacement: pg-node-$1

%{ if pgbouncer_enabled ~}
  # pgbouncer_exporter — one container per PgBouncer instance
  - job_name: pgbouncer
    static_configs:
      - targets:
%{ for i in range(1, pgbouncer_replicas + 1) ~}
          - pgbouncer-exporter-${i}:9127
%{ endfor ~}
    relabel_configs:
      - source_labels: [__address__]
        regex: 'pgbouncer-exporter-(\d+):.*'
        target_label: instance
        replacement: pgbouncer-$1
%{ endif ~}
