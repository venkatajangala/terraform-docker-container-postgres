// HA Cluster Test Configuration
// Based on previous single-node deployment credentials

postgres_user         = "pgadmin"
postgres_password     = "pgAdmin1"
postgres_db           = "postgres"
replication_password  = "replicator1"
dbhub_port            = 9090
etcd_port             = 12379
etcd_peer_port        = 12380
patroni_api_port_base = 8008

// PgBouncer Configuration
pgbouncer_enabled            = true
pgbouncer_replicas           = 2
pgbouncer_external_port_base = 6432
pgbouncer_pool_mode          = "transaction"
pgbouncer_max_client_conn    = 1000
pgbouncer_default_pool_size  = 25
pgbouncer_min_pool_size      = 5
pgbouncer_reserve_pool_size  = 5
