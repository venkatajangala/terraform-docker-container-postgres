## Datadog PgBouncer integration — rendered by Terraform (passwords injected at plan time)
## Connects to each pgbouncer instance's admin console (database=pgbouncer).
## pgadmin is listed in admin_users and stats_users in pgbouncer.ini.

init_config:

instances:
%{ for replica in pgbouncer_replicas ~}
  - host: pgbouncer-${replica}
    port: 6432
    username: ${pgbouncer_user}
    password: "${pgbouncer_password}"
    dbname: pgbouncer
    tags:
      - "instance:pgbouncer-${replica}"
      - "cluster:pg-ha-cluster"
      - "service:pgbouncer"

%{ endfor ~}
