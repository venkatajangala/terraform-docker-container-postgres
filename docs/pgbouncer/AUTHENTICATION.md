# 🔐 PgBouncer Authentication & Configuration

Comprehensive guide to PgBouncer authentication, password handling, and configuration for this PostgreSQL HA cluster.

## Overview

This setup uses **SCRAM-SHA-256 authentication** with passwords stored in a userlist file that is **dynamically generated** by `entrypoint-pgbouncer.sh` at container startup using Terraform-supplied environment variables.

### Why SCRAM-SHA-256?

- ✅ No MD5 hashing vulnerability
- ✅ Secure challenge-response authentication
- ✅ Compatible with modern PostgreSQL
- ✅ Password transmitted securely over network
- ✅ No plaintext password transmission to database

---

## Current Configuration

### File: `pgbouncer/pgbouncer.ini`

```ini
; Authentication
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
```

### File: `pgbouncer/userlist.txt`

This file is **generated at container startup** by `entrypoint-pgbouncer.sh`. It is not committed to git. To see current passwords:

```bash
terraform output generated_passwords
```

The generated format looks like:

```text
"pgadmin"    "<password from generated_passwords>"
"replicator" "<replicator password from generated_passwords>"
```

---

## Authentication Methods

### Method 1: Environment Variable (Recommended for Scripts)

```bash
# Get password first
terraform output generated_passwords

export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres
unset PGPASSWORD
```

**Use Case:** Shell scripts, automation, CI/CD pipelines

**Security:**

- ✅ Password not visible in process list
- ✅ Unset after use
- ❌ Visible in shell history (use `set +o history` to prevent)

---

### Method 2: Connection String (Recommended for Applications)

```text
postgresql://pgadmin:<password from generated_passwords>@localhost:6432/postgres

# With parameters
postgresql://pgadmin:<password from generated_passwords>@localhost:6432/postgres?sslmode=disable
```

**Use Case:** Application connection strings (Python, Java, Node.js, etc.)

**Examples:**

**Python:**

```python
import psycopg2
conn = psycopg2.connect(
    host='localhost',
    port=6432,
    database='postgres',
    user='pgadmin',
    password='<password from generated_passwords>'
)
```

**Java:**

```java
String dbUrl = "jdbc:postgresql://localhost:6432/postgres";
Properties props = new Properties();
props.setProperty("user", "pgadmin");
props.setProperty("password", "<password from generated_passwords>");
Connection conn = DriverManager.getConnection(dbUrl, props);
```

**Node.js:**

```javascript
const { Client } = require('pg');
const client = new Client({
    host: 'localhost',
    port: 6432,
    database: 'postgres',
    user: 'pgadmin',
    password: '<password from generated_passwords>'
});
```

**Go:**

```go
dsn := "postgres://pgadmin:<password from generated_passwords>@localhost:6432/postgres"
db, err := sql.Open("postgres", dsn)
```

---

### Method 3: .pgpass File (For Interactive Sessions)

Create `~/.pgpass`:

```text
localhost:6432:postgres:pgadmin:<password from generated_passwords>
```

Set permissions:

```bash
chmod 600 ~/.pgpass
```

Connect without password prompt:

```bash
psql -h localhost -p 6432 -U pgadmin -d postgres
```

**Security:**

- ✅ No password in shell history
- ✅ Automatic password lookup
- ❌ File stored in home directory (protect with chmod 600)

---

### Method 4: Interactive Password Prompt

```bash
psql -h localhost -p 6432 -U pgadmin -d postgres -W
```

The `-W` flag prompts for password.

**Use Case:** Interactive troubleshooting

---

## Docker Execution

### For Docker Exec Commands

```bash
# Method 1: Using bash -c with PGPASSWORD
docker exec pgbouncer-1 bash -c "PGPASSWORD='<password from generated_passwords>' psql -h localhost -p 6432 -U pgadmin -d postgres -c \"SELECT version();\""

# Method 2: Using -e for environment variable
docker exec -e PGPASSWORD='<password from generated_passwords>' pgbouncer-1 psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT version();"

# Method 3: Interactive with -it
docker exec -it pgbouncer-1 bash
# Then inside container: PGPASSWORD='<password from generated_passwords>' psql -h localhost -p 6432 -U pgadmin -d postgres
```

---

## User Management

### Adding a New User

Edit `pgbouncer/userlist.txt` (or update via Terraform variables), then reload:

```text
"pgadmin"    "<password from generated_passwords>"
"replicator" "<replicator password from generated_passwords>"
"newuser"    "newpassword"
```

```bash
docker restart pgbouncer-1 pgbouncer-2
```

---

### Changing a Password

Update the Terraform variable (`TF_VAR_postgres_password`) or let Terraform regenerate, then:

```bash
# Re-apply to regenerate userlist.txt and update container environment
terraform apply -var-file="ha-test.tfvars"

# Then update the running PostgreSQL user (if cluster is already running)
LEADER=$(curl -s http://localhost:8008/leader | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
docker exec -it "$LEADER" psql -U postgres -d postgres \
  -c "ALTER USER pgadmin PASSWORD '<new password from generated_passwords>';"

# Restart PgBouncer to pick up new userlist
docker restart pgbouncer-1 pgbouncer-2
```

---

## Configuration Parameters

### Authentication Settings

| Parameter | Value | Description |
| --------- | ----- | ----------- |
| `auth_type` | `scram-sha-256` | Authentication method |
| `auth_file` | `/etc/pgbouncer/userlist.txt` | User credentials file |
| `auth_user` | (not set) | User for auth_query (disabled) |
| `auth_query` | (not set) | Query for external auth (disabled) |

### Connection Pooling

| Parameter | Value | Description |
| --------- | ----- | ----------- |
| `pool_mode` | `transaction` | Pooling strategy |
| `max_client_conn` | `1000` | Max simultaneous client connections |
| `default_pool_size` | `25` | Connections per database/user |
| `min_pool_size` | `5` | Minimum pool size |
| `reserve_pool_size` | `5` | Reserve connections |

### Network Settings

| Parameter | Value | Description |
| --------- | ----- | ----------- |
| `listen_addr` | `0.0.0.0` | Bind address |
| `listen_port` | `6432` | PgBouncer port |
| `unix_socket_dir` | `/var/run/postgresql` | Unix socket location |

---

## Security Best Practices

### For Production

1. **Rotate Passwords Regularly** — Let Terraform regenerate via `random_password`, or use Infisical for automated rotation.

2. **Enable SSL/TLS:**

   ```ini
   [pgbouncer]
   cert_file = /etc/pgbouncer/server.crt
   key_file  = /etc/pgbouncer/server.key
   ```

3. **Restrict Network Access:**

   ```bash
   # Only allow from your application network
   docker network create --restricted app-network
   ```

4. **Enable Logging:**

   ```ini
   [pgbouncer]
   log_connections   = 1
   log_disconnections = 1
   log_pooler_errors = 1
   ```

5. **Audit Authentication:**

   ```bash
   docker logs pgbouncer-1 | grep "authentication failed"
   ```

### Development (Current Setup)

✅ Suitable for:

- Local development
- Testing
- Proof of concept

⚠️ Not suitable for:

- Production environments
- Sensitive data
- Multi-team access without further hardening

---

## Troubleshooting

### "fe_sendauth: no password supplied"

**Cause:** Password not provided to psql

**Fix:**

```bash
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres

# Or use -W for interactive prompt
psql -h localhost -p 6432 -U pgadmin -d postgres -W

# Or use connection string with password
psql "postgresql://pgadmin:<password from generated_passwords>@localhost:6432/postgres"
```

---

### "password authentication failed"

**Cause:** Incorrect password or user not in userlist.txt

**Check:**

```bash
# Get current generated password
terraform output -json generated_passwords

# Verify container's userlist
docker exec pgbouncer-1 cat /etc/pgbouncer/userlist.txt

# Check logs
docker logs pgbouncer-1 | grep "password authentication failed"
```

---

### "invalid user specification"

**Cause:** User not in quotes in userlist.txt

**Fix:**

```ini
# CORRECT — with quotes
"pgadmin" "<password from generated_passwords>"

# WRONG — without quotes
pgadmin <password>
```

---

### "auth_type is invalid"

**Cause:** Invalid authentication method

**Valid Options:**

- `trust` — No authentication
- `reject` — Reject all
- `md5` — MD5 hashing (obsolete)
- `scram-sha-256` — SCRAM negotiation (recommended)
- `cert` — Certificate authentication
- `pam` — PAM authentication
- `hba` — PostgreSQL HBA file

**Fix:**

```ini
auth_type = scram-sha-256  # Must be exact
```

---

## Admin Console Access

### Connect to PgBouncer Admin Database

```bash
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d pgbouncer

# Or with -W
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -W
```

### Available Admin Commands

```sql
-- Show current pools
SHOW POOLS;

-- Show connection statistics
SHOW STATS;

-- Show active clients
SHOW CLIENTS;

-- Show server connections
SHOW SERVERS;

-- Show configuration
SHOW CONFIG;

-- Reload configuration
RELOAD;

-- Pause pooler
PAUSE;

-- Resume pooler
RESUME;
```

---

## Configuration Reload

PgBouncer supports live configuration reload without dropping connections:

```bash
# Reload via admin console
PGPASSWORD='<password from generated_passwords>' psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "RELOAD;"

# Or restart containers
docker restart pgbouncer-1 pgbouncer-2

# Or send SIGHUP signal
docker kill -s HUP pgbouncer-1
```

**What Gets Reloaded:**

- ✅ User list (userlist.txt)
- ✅ Connection pool settings
- ✅ Database routing
- ❌ Port and bind address (requires restart)

---

## Testing Authentication

### Simple Test

```bash
export PGPASSWORD='<password from generated_passwords>'
psql -h localhost -p 6432 -U pgadmin -d postgres -c "SELECT version();"
```

**Expected Output:**

```text
PostgreSQL 18.2 (Debian 18.2-1.pgdg13+1)
```

### Comprehensive Test

```bash
export PGPASSWORD='<password from generated_passwords>'

# Test 1: Version check
psql -h localhost -p 6432 -U pgadmin -c "SELECT version();"

# Test 2: Database list
psql -h localhost -p 6432 -U pgadmin -l

# Test 3: Admin console
psql -h localhost -p 6432 -U pgadmin -d pgbouncer -c "SHOW POOLS;"

# Test 4: Replication status
psql -h localhost -p 6432 -U pgadmin -d postgres \
  -c "SELECT application_name, state, sync_state, write_lag FROM pg_stat_replication;"

unset PGPASSWORD
```

---

## Performance Tuning

### Connection Pool Sizing

```ini
[pgbouncer]
# For web applications (short queries)
default_pool_size = 25    # Per DB/user
max_client_conn = 1000    # Total connections

# For batch processing (long transactions)
default_pool_size = 5
max_client_conn = 500

# For high-throughput (many short connections)
default_pool_size = 50
max_client_conn = 2000
```

### Pool Mode Selection

| Mode | Use Case | Overhead |
| ---- | -------- | -------- |
| `statement` | Multiple queries per transaction | Lowest |
| `transaction` | Default, most apps | Low |
| `session` | Application needs transaction state | High |

---

## Related Documentation

- **[Quick Start](../getting-started/01-QUICK-START.md)** — Deployment guide
- **[Operations](../guides/02-OPERATIONS.md)** — Daily operations
- **[Testing](../testing/TESTING.md)** — Test procedures
- **[Troubleshooting](../guides/03-TROUBLESHOOTING.md)** — Common issues
