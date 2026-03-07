# PgBouncer HA Configuration Guide

## Overview

PgBouncer is a lightweight, efficient connection pooler for PostgreSQL. This configuration adds a **highly available, scalable connection pooling layer** to your existing Patroni-managed PostgreSQL HA cluster.

## Architecture

```
Application Clients
       ↓
    ┌─────────────────────────────────┐
    │   PgBouncer HA (Load Balanced)  │
    │  ┌──────────┬──────────┐        │
    │  │Bouncer-1 │Bouncer-2 │        │
    │  └────┬─────┴────┬─────┘        │
    │       │          │              │
    └───────┼──────────┼──────────────┘
            │          │
    ┌───────┴──────────┴──────────────┐
    │  Patroni HA PostgreSQL Cluster  │
    │  ┌──────┬──────┬──────┐         │
    │  │Node-1│Node-2│Node-3│         │
    │  └──────┴──────┴──────┘         │
    │  (Primary + Replicas)           │
    │  (Auto-failover via etcd)       │
    └─────────────────────────────────┘
```

## Features

✅ **HA Configuration**: 2-3 PgBouncer instances for high availability  
✅ **Connection Pooling**: Reduces PostgreSQL connection overhead  
✅ **Transaction Mode**: Supports transaction-level connection reuse  
✅ **Multi-node Routing**: Automatically routes to all Patroni nodes  
✅ **Health Checks**: Docker health checks on each instance  
✅ **Logging & Monitoring**: Detailed logs and statistics collection  
✅ **Flexible Configuration**: Customizable via variables  

## Components

### Files Created

```
├── Dockerfile.pgbouncer           # PgBouncer Docker image
├── pgbouncer/                     # PgBouncer configuration
│   ├── pgbouncer.ini             # Main configuration
│   └── userlist.txt              # User credentials
└── main-ha.tf                    # Updated with PgBouncer containers
```

## Configuration Variables

Add these to your `terraform.tfvars` or `ha-test.tfvars`:

```hcl
# Enable PgBouncer connection pooling
pgbouncer_enabled              = true

# Number of HA instances (1-3)
pgbouncer_replicas             = 2

# External port base (instances use +0, +1, +2)
pgbouncer_external_port_base   = 6432

# Connection pooling mode: session, transaction, statement
pgbouncer_pool_mode            = "transaction"

# Maximum client connections per instance
pgbouncer_max_client_conn      = 1000

# Default pool size per database
pgbouncer_default_pool_size    = 25

# Minimum available connections
pgbouncer_min_pool_size        = 5

# Emergency reserve connections
pgbouncer_reserve_pool_size    = 5
```

## Pool Modes Explained

### **Transaction Mode** (RECOMMENDED - Default)
- ✅ New connection from pool per transaction
- ✅ Full compatibility with PostgreSQL behavior
- ✅ Best for most applications
- ⏱️ Slightly more overhead but maximum compatibility

```hcl
pgbouncer_pool_mode = "transaction"
```

### **Session Mode**
- ✅ Connection reused for entire session
- ⚠️ Requires careful application state management
- ✅ Lower overhead than transaction mode

```hcl
pgbouncer_pool_mode = "session"
```

### **Statement Mode**
- ✅ Maximum connection reuse
- ⚠️ Statement-level pooling, very limited compatibility
- ⏱️ Only for specific use cases

```hcl
pgbouncer_pool_mode = "statement"
```

## Deployment

### 1. Update Configuration

Edit `ha-test.tfvars`:

```hcl
pgbouncer_enabled            = true
pgbouncer_replicas           = 2
pgbouncer_external_port_base = 6432
pgbouncer_pool_mode          = "transaction"
```

### 2. Deploy with Terraform

```bash
cd /home/vejang/terraform-docker-container-postgres
terraform init
terraform plan -var-file="ha-test.tfvars"
terraform apply -var-file="ha-test.tfvars"
```

### 3. Verify Deployment

```bash
# Check PgBouncer containers
docker ps | grep pgbouncer

# Check container logs
docker logs pgbouncer-1
docker logs pgbouncer-2

# List containers
docker container ls --filter name=pgbouncer
```

## Connection Examples

### Via PgBouncer (Recommended)

```bash
# Pooled connection via PgBouncer
psql -h localhost -p 6432 -U pgadmin -d postgres

# Alternative: specify host directly
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT version();"

# Connection string
postgresql://pgadmin:pgAdmin1@localhost:6432/postgres

# For application (JDBC, Python, etc.)
jdbc:postgresql://localhost:6432/postgres
```

### Direct PostgreSQL (Legacy - Bypasses Pooling)

```bash
# Direct to primary (port 5432)
psql -h localhost -p 5432 -U pgadmin -d postgres

# Direct to replica 1 (port 5433) - read-only
psql -h localhost -p 5433 -U pgadmin -d postgres

# Direct to replica 2 (port 5434) - read-only
psql -h localhost -p 5434 -U pgadmin -d postgres
```

## Accessing PgBouncer Admin Console

```bash
# Connect to admin console (requires pgadmin user)
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Show pool statistics
pgbouncer> SHOW POOLS;

# Show current connections
pgbouncer> SHOW CLIENTS;

# Show servers in pool
pgbouncer> SHOW SERVERS;

# Reload configuration
pgbouncer> RELOAD;

# Check pool status
pgbouncer> SHOW STATS;

# Disconnect pools
pgbouncer> WAIT_CLOSE;
```

## PgBouncer Admin Commands

Available in PgBouncer admin console:

```sql
-- Pool statistics
SHOW POOLS;              -- Connection pools information
SHOW DATABASES;          -- Configured databases
SHOW CLIENTS;            -- Connected clients
SHOW SERVERS;            -- Backend server connections
SHOW STATS;              -- Detailed statistics
SHOW CONFIG;             -- Current configuration
SHOW VERSION;            -- PgBouncer version

-- Management
RELOAD;                  -- Reload configuration files
PAUSE;                   -- Pause all queries
RESUME;                  -- Resume paused queries
RECONNECT;               -- Reconnect to all servers
WAIT_CLOSE;             -- Wait for clients to disconnect
KILL name conn_string;  -- Kill specific connection

-- Info
SHOW HELP;               -- Show available commands
```

## Performance Tuning

### For High Connection Load

```hcl
pgbouncer_max_client_conn     = 2000
pgbouncer_default_pool_size   = 50
pgbouncer_min_pool_size       = 10
pgbouncer_reserve_pool_size   = 10
pgbouncer_replicas            = 3  # More instances
```

### For Low-Latency Environments

```hcl
pgbouncer_pool_mode           = "session"
pgbouncer_default_pool_size   = 10
pgbouncer_min_pool_size       = 3
pgbouncer_reserve_pool_size   = 2
pgbouncer_replicas            = 2
```

### For Memory-Constrained Environments

```hcl
pgbouncer_max_client_conn     = 500
pgbouncer_default_pool_size   = 10
pgbouncer_min_pool_size       = 3
pgbouncer_reserve_pool_size   = 1
pgbouncer_replicas            = 1  # Single instance
```

## Monitoring

### Docker Logs

```bash
# View PgBouncer logs
docker logs pgbouncer-1 -f
docker logs pgbouncer-2 -f

# Get log summary
docker logs pgbouncer-1 | grep ERROR
docker logs pgbouncer-1 | grep WARNING
```

### Health Checks

```bash
# Check if PgBouncer is healthy
docker inspect pgbouncer-1 --format='{{.State.Health.Status}}'

# Test connection
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;"
```

### Connection Statistics

```bash
# Connect to pgbouncer admin database
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Get real-time statistics
SELECT * FROM pgbouncer.stats;

# Monitor over time
SELECT usename, count(*) FROM pgbouncer.clients GROUP BY usename;
```

## Troubleshooting

### Issue: PgBouncer Can't Connect to PostgreSQL Nodes

```bash
# Check network connectivity between containers
docker exec pgbouncer-1 nc -zv pg-node-1 5432
docker exec pgbouncer-1 nc -zv pg-node-2 5432
docker exec pgbouncer-1 nc -zv pg-node-3 5432

# Check PgBouncer logs
docker logs pgbouncer-1
```

### Issue: "Authentication Failed"

```bash
# Verify credentials in pgbouncer/userlist.txt
cat pgbouncer/userlist.txt

# Check PostgreSQL is accepting connections
dbuser=$(docker exec pg-node-1 psql -U pgadmin -d postgres -c "SELECT 1;")

# Verify pg_hba.conf allows connections
docker exec pg-node-1 psql -U pgadmin -d postgres -c "SHOW hba_file;"
```

### Issue: "Connection Limit Exceeded"

```bash
# Check current connections
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"

# Increase pool size
# Update ha-test.tfvars:
# pgbouncer_default_pool_size = 50  (instead of 25)

# Reapply Terraform
terraform apply -var-file="ha-test.tfvars"
```

### Issue: Slow Queries Through PgBouncer

```bash
# Profile with transaction mode
pgbouncer_pool_mode = "transaction"

# Or switch to session mode if appropriate
pgbouncer_pool_mode = "session"

# Check query performance
docker exec pg-node-1 psql -U pgadmin -d postgres -c \
  "SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY mean_time DESC;"
```

## Upgrading PgBouncer

```bash
# Rebuild the image
terraform taint docker_image.pgbouncer[0]
terraform apply -var-file="ha-test.tfvars"

# Or manually
docker image rm pgbouncer:ha
docker build -f Dockerfile.pgbouncer -t pgbouncer:ha .
docker-compose restart pgbouncer-1 pgbouncer-2
```

## Scaling Considerations

### Horizontal Scaling (More Instances)

```hcl
# Increase number of poolers
pgbouncer_replicas = 3

# Use load balancer or DNS round-robin to distribute connections
# Example (external LB):
#   app1 -> 6432 (pgbouncer-1)
#   app2 -> 6433 (pgbouncer-2)
#   app3 -> 6434 (pgbouncer-3)
```

### Vertical Scaling (Larger Pool)

```hcl
# Increase pool sizes
pgbouncer_default_pool_size   = 50
pgbouncer_max_client_conn     = 2000
pgbouncer_reserve_pool_size   = 10
```

## Best Practices

✅ **Always use Transaction Mode** for maximum compatibility  
✅ **Monitor connection metrics** regularly  
✅ **Set appropriate pool sizes** based on your workload  
✅ **Use separate PgBouncer instances** for read/write separation (advanced)  
✅ **Enable logging** for debugging  
✅ **Test failover scenarios** with PgBouncer  
✅ **Update userlist.txt** when adding PostgreSQL users  
✅ **Keep PgBouncer version** synchronized with PostgreSQL  

## Reference Documentation

- [PgBouncer Official Docs](https://pgbouncer.github.io/)
- [PgBouncer Configuration](https://pgbouncer.github.io/config.html)
- [PgBouncer Admin Console](https://pgbouncer.github.io/usage.html)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL Connection Management](https://www.postgresql.org/docs/current/runtime-config-connection.html)

## Summary

Your PgBouncer HA setup is now configured with:

- **2 PgBouncer instances** (configurable 1-3)
- **Connection pooling** on ports 6432, 6433, 6434
- **Transaction mode** for maximum compatibility
- **Automatic routing** to all 3 Patroni nodes
- **Health checks** and monitoring
- **Full Terraform automation**

Connect applications via `localhost:6432` for pooled connections with automatic failover support!
