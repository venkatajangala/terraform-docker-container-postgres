# PgBouncer Quick Start Guide

## 🚀 Quick Deployment (5 minutes)

### Step 1: Verify Current Setup

```bash
cd /home/vejang/terraform-docker-container-postgres

# Verify your HA cluster is running
docker ps | grep -E 'pg-node|etcd|pgbouncer'

# Check terraform state
terraform state list
```

### Step 2: Enable PgBouncer in Configuration

Edit `ha-test.tfvars` and ensure:

```hcl
pgbouncer_enabled            = true
pgbouncer_replicas           = 2
pgbouncer_external_port_base = 6432
pgbouncer_pool_mode          = "transaction"
```

### Step 3: Deploy PgBouncer

```bash
# Initialize (if first time)
terraform init

# Plan the deployment
terraform plan -var-file="ha-test.tfvars" -target='docker_image.pgbouncer' -target='docker_container.pgbouncer_1' -target='docker_container.pgbouncer_2'

# Apply
terraform apply -var-file="ha-test.tfvars" -target='docker_image.pgbouncer' -target='docker_container.pgbouncer_1' -target='docker_container.pgbouncer_2'

# Or deploy everything
terraform apply -var-file="ha-test.tfvars"
```

### Step 4: Verify Deployment

```bash
# Check PgBouncer containers are running
docker ps | grep pgbouncer

# Check logs
docker logs pgbouncer-1
docker logs pgbouncer-2

# Test connection health
docker inspect pgbouncer-1 --format='{{.State.Health.Status}}'
docker inspect pgbouncer-2 --format='{{.State.Health.Status}}'
```

## 🔌 Quick Connection Test

### Connect via PgBouncer (Pooled)

```bash
# Test connection to pgbouncer-1
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT version();"

# Test connection to pgbouncer-2
psql -h localhost -p 6433 -U pgadmin -d postgres -c "SELECT version();"

# Or as connection string
psql postgresql://pgadmin:pgAdmin1@localhost:6432/postgres
```

### Verify Connection Pooling

```bash
# Connect to PgBouncer admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Inside psql>
pgbouncer=> SHOW POOLS;
pgbouncer=> SHOW STATS;
pgbouncer=> SHOW CLIENTS;
pgbouncer=> \q
```

## 📊 Expected Output

After deployment:

```
Terraform will perform the following actions:

  # docker_image.pgbouncer[0] will be created
  + resource "docker_image" "pgbouncer" {
      + id   = (known after apply)
      + name = "pgbouncer:ha"
    }

  # docker_container.pgbouncer_1[0] will be created
  + resource "docker_container" "pgbouncer_1" {
      + image      = (known after apply)
      + name       = "pgbouncer-1"
      + ports {
          + external = 6432
          + internal = 6432
        }
    }

  # docker_container.pgbouncer_2[0] will be created
  + resource "docker_container" "pgbouncer_2" {
      + image      = (known after apply)
      + name       = "pgbouncer-2"
      + ports {
          + external = 6433
          + internal = 6432
        }
    }
```

## 🎯 Common Tasks

### View PgBouncer Configuration

```bash
# From host
cat pgbouncer/pgbouncer.ini | head -50

# From PgBouncer admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW CONFIG;"
```

### Monitor Active Connections

```bash
# Watch real-time connections
watch -n 1 'psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW CLIENTS;" 2>/dev/null | tail -10'

# Or via logs
docker logs pgbouncer-1 -f | grep -E 'client|server|pool'
```

### Check Database Pool Status

```bash
psql -h localhost -p 6432 -U pgadmin -d pgbouncer << EOF
SHOW POOLS;
EOF
```

### Reload Configuration

```bash
# Connect to PgBouncer admin
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "RELOAD;"

# Or restart container
docker restart pgbouncer-1 pgbouncer-2
```

### Add New Database

Edit `pgbouncer/pgbouncer.ini`:

```ini
[databases]
postgres = host=pg-node-1,pg-node-2,pg-node-3 port=5432 dbname=postgres
pgadmin = host=pg-node-1,pg-node-2,pg-node-3 port=5432 dbname=postgres
myapp = host=pg-node-1,pg-node-2,pg-node-3 port=5432 dbname=myapp
```

Then reload:

```bash
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "RELOAD;"
```

## 🔧 Customization Examples

### High Performance Setup

Edit `ha-test.tfvars`:

```hcl
pgbouncer_replicas            = 3
pgbouncer_pool_mode           = "transaction"
pgbouncer_max_client_conn     = 2000
pgbouncer_default_pool_size   = 50
pgbouncer_min_pool_size       = 10
```

Apply changes:

```bash
terraform apply -var-file="ha-test.tfvars"
```

### Session Mode (Less Overhead)

```hcl
pgbouncer_pool_mode = "session"
```

⚠️ Note: Session mode requires careful application state management.

### Single Instance (Development)

```hcl
pgbouncer_enabled   = true
pgbouncer_replicas  = 1
```

## 🐛 Troubleshooting

### PgBouncer Failed to Start

```bash
# Check logs
docker logs pgbouncer-1

# Verify configuration syntax
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;" 2>&1

# Rebuild image
docker image rm pgbouncer:ha
terraform apply -var-file="ha-test.tfvars"
```

### Connection Refused

```bash
# Verify PgBouncer is running
docker ps | grep pgbouncer-1

# Check if port is open
netstat -tlnp | grep 6432
# or
lsof -i :6432

# Test internal connectivity
docker exec pgbouncer-1 psql -h pg-node-1 -p 5432 -U pgadmin -d postgres -c "SELECT 1;"
```

### Authentication Failed

```bash
# Verify userlist.txt exists
cat pgbouncer/userlist.txt

# Check PostgreSQL user exists
docker exec pg-node-1 psql -U pgadmin -d postgres -c "SELECT usename FROM pg_user WHERE usename='pgadmin';"

# Verify pg_hba.conf allows connections from PgBouncer
docker exec pg-node-1 psql -U pgadmin -d postgres -c "SHOW hba_file;"
```

## 📈 Performance Monitoring

### View Statistics

```bash
# Real-time statistics
psql -h localhost -p 6432 -U pgadmin -d pgbouncer << EOF
SELECT 
    database, 
    user, 
    cl_active, 
    cl_waiting, 
    sv_active, 
    sv_idle
FROM pgbouncer.stats;
EOF
```

### Check Connection Overhead

```bash
# Before PgBouncer (direct)
time for i in {1..100}; do psql -h localhost -p 5432 -U pgadmin -d postgres -c "SELECT 1;" > /dev/null; done

# After PgBouncer (pooled)
time for i in {1..100}; do psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT 1;" > /dev/null; done

# Via PgBouncer should be significantly faster!
```

## 🚀 Next Steps

1. **Configure your application** to connect via `localhost:6432`
2. **Monitor connection metrics** using the admin console
3. **Adjust pool sizes** based on your workload
4. **Test failover** by stopping a PgBouncer instance
5. **Set up load balancing** (optional, for multiple instances)

## 📚 Resources

- [Full Setup Guide](./PGBOUNCER-SETUP.md)
- [PgBouncer Official Docs](https://pgbouncer.github.io/)
- [Terraform Configuration](./main-ha.tf)
- [Environment Variables](./ha-test.tfvars)

---

**Questions?** Check the full [PGBOUNCER-SETUP.md](./PGBOUNCER-SETUP.md) guide for detailed information!
