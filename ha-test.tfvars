// HA Cluster Test Configuration
// Based on previous single-node deployment credentials

postgres_user              = "pgadmin"
postgres_password          = "pgAdmin1"
postgres_db                = "postgres"
replication_password       = "replicator1"
dbhub_port                 = 9090
etcd_port                  = 12379
etcd_peer_port             = 12380
patroni_api_port_base      = 8008
