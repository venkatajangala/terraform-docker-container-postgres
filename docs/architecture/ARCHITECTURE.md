# 🏗️ Architecture Overview

Complete technical architecture of the PostgreSQL HA cluster with PgBouncer.

## System Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                        APPLICATION LAYER                            │
│  (Your apps, scripts, dashboards, monitoring tools)                │
└─────────────────────────┬──────────────────────────────────────────┘
                          │
                ┌─────────▼──────────┐
                │   PgBouncer HA     │  ← Connection Pooling Layer
                │ ┌────────┬────────┐│     Reduces connection overhead
                │ │Bouncer-1│Bouncer-2││     Supports 1000s of clients
                │ │ 6432   │ 6433  ││     Transaction-level pooling
                │ └────────┴────────┘│
                └─────────┬──────────┘
                          │ (TCP 6432/6433)
        ┌─────────────────┼────────────────┐
        │                 │                │
    ┌───▼───┐        ┌────▼────┐     ┌────▼────┐
    │PG-Node-1(PRIMARY)│PG-Node-2│    │PG-Node-3│  ← PostgreSQL HA Cluster
    │ Port:5432   │(REPLICA)   │    │(REPLICA)│     Synchronous replication
    │ Patroni:8008│ 5433:8009  │    │ 5434:8010    Automatic failover
    └────┬─────────┘────┬───────┘    └─────┬─────┘
         │              │                  │
         └──────────────┼──────────────────┘
                        │ WAL Streaming & Replication
                        │
        ┌───────────────▼────────────────┐
        │  etcd Cluster (Distributed)    │   ← Consensus Layer
        │  Port: 2379/2380               │     Leader election
        │  - Cluster state               │     Config management
        │  - Leader record               │     Safe failover
        │  - Member registry             │
        └───────────────────────────────┘
                        │
        ┌───────────────▼────────────────┐
        │  DBHub/Bytebase (Optional)      │   ← Web Management UI
        │  Port: 9090                     │     Database browser
        │  Schema viewer, query execution │     Migration support
        └─────────────────────────────────┘
```

## Component Details

### 1. PostgreSQL Cache (3 Nodes)

#### Primary Node (pg-node-1)
- **Port**: 5432 (PostgreSQL), 8008 (Patroni API)
- **Role**: Accepts writes, replicates to replicas
- **Database**: PostgreSQL 18.2
- **Extensions**: pgvector, uuid-ossp, pg_stat_statements
- **Status**: Elected via etcd consensus

#### Replica Nodes (pg-node-2, pg-node-3)
- **Ports**: 5433/5434 (PostgreSQL), 8009/8010 (Patroni API)
- **Role**: Accept reads, replicate from primary
- **Status**: Continuous streaming replication
- **Promotion**: Can become primary if current primary fails

#### Replication Details
- **Type**: Synchronous stream replication
- **Slots**: Replication slots for safe LSN tracking
- **Connection**: Direct TCP between nodes
- **Topology**: Primary → Replicas (one-way data flow)

### 2. Patroni Orchestration Layer

#### What It Does
- **Leader Election**: Elects primary via etcd quorum
- **Health Checks**: Monitors all nodes every 10 seconds
- **Configuration Management**: Stores config in etcd, applies to all nodes
- **Failover Coordination**: Promotes best replica to primary when needed
- **API Server**: REST endpoint for status and commands

#### How It Works
```
Patroni on each node:
  ↓
Connects to etcd every 10 seconds
  ↓
Reports own health via heartbeat
  ↓
Reads leader record from etcd
  ↓
If I'm the leader: Maintain leadership
If I'm not:        Replicate from leader
  ↓
If leader dies:    Coordinate election via etcd
  ↓
etcd quorum decides:
  - Who's next leader
  - When to trigger failover
  - Which replica promotes
```

#### Failover Scenario
```
Time 0:00 - Primary healthy
[pg-1 LEADER] ← pg-2 ← pg-3

Time 0:15 - Primary network issue detected
[pg-1 ???]     pg-2     pg-3
             (detecting failure...)

Time 0:30 - Patroni on pg-2 wins election
[pg-1 OFFLINE] [pg-2 NEW LEADER] ← pg-3

Time 0:45 - pg-1 comes back online, rejoins as replica
[pg-1 REPLICA] ← [pg-2 LEADER] ← pg-3
```

### 3. etcd Distributed Consensus

#### Purpose
```
etcd stores:
  /pg-ha-cluster/leader       → Which node is leader
  /pg-ha-cluster/members/*    → All active members
  /pg-ha-cluster/sync         → Sync state info
  /pg-ha-cluster/config       → Cluster configuration
  /pg-ha-cluster/optime       → Replication positions
```

#### How It Ensures Safety
- **Quorum-based**: All changes require majority vote (2/3 nodes)
- **Atomic**: Either all nodes agree or change doesn't happen
- **Persistent**: Data survives container restarts
- **Distributed**: No single point of failure

#### Leader Election Algorithm
```
All Patroni nodes compete for leadership:
  
Conditions to win:
  1. Has most recent WAL position
  2. Can respond to health check
  3. Has quorum agreement in etcd
  
Winner becomes leader, gets lock in etcd
  
Others become followers, replicate from leader

If leader dies:
  Its lock expires in etcd (30 second TTL)
  Next-best candidate wins new election
  Happens in < 30 seconds total
```

### 4. PgBouncer Connection Pooling

#### Architecture
```
1000s of Client Connections
        ↓
    PgBouncer Proxy
    (2 instances for HA)
        ↓
    Connection Pools
    ├─ pg-node-1 pool (25 connections)
    ├─ pg-node-2 pool (25 connections)
    └─ pg-node-3 pool (25 connections)
    Total: ~100 real database connections
        ↓
    PostgreSQL Backend
```

#### How Connection Pooling Works

**Without PgBouncer:**
```
Client 1 → PostgreSQL   (creates connection)
Client 2 → PostgreSQL   (creates connection)
Client 3 → PostgreSQL   (creates connection)
...
Client 1000 → PostgreSQL (creates 1000th connection!)

Problem: PostgreSQL has overhead per connection
        Memory per connection, file descriptor per connection, etc.
        Can't handle 1000s of client connections efficiently
```

**With PgBouncer:**
```
Client 1   ──┐
Client 2   ──├→ PgBouncer → {reuses 25 connections} → PostgreSQL
Client 3   ──┤             Multiplexing
...          │
Client 1000 ─┘

Benefit: Only 25 backend connections instead of 1000
        Huge memory and resource savings
        Each database can support 1000s of clients
```

#### Pool Modes

**Transaction Mode (Current)** ✅
```
Per Transaction:
1. Client connects to PgBouncer
2. Sends query (SELECT/INSERT/UPDATE)
3. Connection returned to pool
4. Next client reuses same backend connection

Pro: Maximum connection reuse, works with all apps
Con: Slight overhead per transaction
```

**Session Mode**
```
Per Session:
1. Client connects to PgBouncer
2. Connection assigned from pool
3. Connection stays assigned for entire session
4. Session state preserved

Pro: Faster, lower per-query overhead
Con: Can't reuse connections across sessions
```

**Statement Mode**
```
Per Statement:
1. Each SQL statement gets dedicated connection
2. Connection returned after query

Pro: Maximum connection reuse
Con: Very limited compatibility, breaks many apps
```

### 5. Network Topology

#### Docker Network
```
Network Name: pg-ha-network
Network Type: Docker bridge
CIDR: 172.20.0.0/16

Container IPs:
  pg-node-1:    172.20.0.2
  pg-node-2:    172.20.0.3
  pg-node-3:    172.20.0.4
  etcd:         172.20.0.5
  pgbouncer-1:  172.20.0.6
  pgbouncer-2:  172.20.0.7
  dbhub:        172.20.0.8

Host Access:
  Port 5432 → pg-node-1 (PostgreSQL)
  Port 5433 → pg-node-2 (PostgreSQL)
  Port 5434 → pg-node-3 (PostgreSQL)
  Port 6432 → pgbouncer-1 (PgBouncer)
  Port 6433 → pgbouncer-2 (PgBouncer)
  Port 8008 → pg-node-1 (Patroni API)
  Port 8009 → pg-node-2 (Patroni API)
  Port 8010 → pg-node-3 (Patroni API)
  Port 2379 → etcd (API)
  Port 9090 → dbhub (Web UI)
```

#### Connectivity Flow
```
Host Machine
  ↓
  ├→ localhost:6432 → Docker network → PgBouncer-1 → PostgreSQL nodes
  ├→ localhost:5432 → Docker network → pg-node-1 (direct)
  ├→ localhost:8008 → Docker network → Patroni API
  └→ localhost:9090 → Docker network → DBHub web UI

Between Containers (internal):
  pgbouncer-1 ↔ pg-node-1/2/3 (TCP 5432)
  Patroni ↔ etcd (TCP 2379)
  pg-node → pg-node (TCP 5432 for replication)
```

## Data Flow Scenarios

### Scenario 1: Normal Write Operation

```
Application
  ↓ INSERT/UPDATE
PgBouncer
  ↓ Transaction mode
  (allocates connection from pool)
  ↓
PostgreSQL Primary (pg-node-1)
  ↓ Writes to disk
  ↓ Generates WAL
  ↓ Sends WAL to replicas (stream replication)
  ↓
pg-node-2 (receives WAL)
  ↓
pg-node-3 (receives WAL)
  ↓
All nodes apply write
  ↓
Primary responds to PgBouncer
  ↓
PgBouncer returns result to application
  ↓
Connection returned to pool (ready for next query)
```

### Scenario 2: Read Operation (via Replica)

```
Application
  ↓ SELECT query (read-only)
PgBouncer
  ↓ Selects available backend connection from pool
  ↓
PostgreSQL Replica (pg-node-2 or pg-node-3)
  ↓ Executes read-only query
  ↓ Returns results
  ↓
PgBouncer returns to application
  ↓
Connection returned to pool
```

### Scenario 3: Failover Due to Primary Failure

```
Time 0:00 - Primary dies
pg-node-1: OFFLINE ✗
pg-node-2: HEALTHY
pg-node-3: HEALTHY

Time 0:05 - Patroni detects offline primary
All Patroni instances notice:
  - pg-node-1 not responding
  - Heartbeat missing in etcd
  - Try to acquire leader lock

Time 0:10 - etcd election happens
etcd quorum votes:
  pg-node-2: Highest LSN, wins election
  pg-node-3: Becomes follower
  pg-node-1: Stays offline

Time 0:30 - New primary elected and online
pg-node-1: OFFLINE
pg-node-2: NEW PRIMARY ✓
pg-node-3: REPLICA

PgBouncer discovers:
  - Gets new leader from etcd or Patroni discovery
  - Redirects connections to new primary (pg-node-2)

Time 1:00 - pg-node-1 comes back online
pg-node-1: REJOINED (demoted to replica)
pg-node-1: Starts catching up with pg-node-2
pg-node-3: REPLICA

Result: Cluster healed, all 3 nodes operational again
```

## Resource Requirements

### Minimum (Development)
- **CPU**: 2 cores
- **RAM**: 4 GB
- **Disk**: 10 GB
- **Network**: 100 Mbps

### Recommended (Production)
- **CPU**: 4+ cores
- **RAM**: 16+ GB
- **Disk**: 100+ GB (depends on data volume)
- **Network**: 1 Gbps

### Per Container
```
PostgreSQL:   ~500 MB RAM + data size
Patroni:      ~50 MB RAM
PgBouncer:    ~200 MB RAM + pool buffers
etcd:         ~100 MB RAM
DBHub:        ~500 MB RAM
```

## Failure Modes & Recovery

| Failure | Detection | Recovery | Downtime |
|---------|-----------|----------|----------|
| Primary PostgreSQL crashes | 10-30 sec | Replica promotes to primary | 30 sec |
| Primary network partition | 10-30 sec | Replica promotes (majority vote) | 30 sec |
| Single replica dies | Patroni notice | Remains offline until manual restart | 0 sec (reads go to other replica) |
| etcd node dies | If 2+ of 3 alive | Cluster continues (quorum maintained) | 0 sec |
| Single PgBouncer dies | Automatic health check | Route via other PgBouncer instance | ~1 sec |
| All PgBouncers die | Clients fail | Direct PostgreSQL connection available | ~5 sec (app reconfiguration) |
| Network partition (minority) | 30 sec | Minority partition shuts down | 30 sec |

## Security Boundaries

```
┌─────────────────────────────────────┐
│      Host Machine (Trusted)          │
├─┬───────────────────────────────────┤
│ │ Docker Bridge Network (Isolated)   │
│ │ 172.20.0.0/16                      │
│ ├─ pg-node-1 ───────────────────────┤
│ ├─ pg-node-2 ───────────────────────┤
│ ├─ pg-node-3 ───────────────────────┤
│ ├─ pgbouncer-1 ─────────────────────┤
│ ├─ pgbouncer-2 ─────────────────────┤
│ ├─ etcd ────────────────────────────┤
│ └─ dbhub ──────────────────────────┘
│
│ Ports exposed to host:
│ ├─ 6432/6433 (PgBouncer) - Database access
│ ├─ 5432-5434 (PostgreSQL direct) - Direct access (if enabled)
│ ├─ 8008-8010 (Patroni API) - Cluster API
│ ├─ 2379 (etcd API) - Cluster management
│ └─ 9090 (DBHub) - Web management
│
└─────────────────────────────────────┘

Default Authentication:
  - pgbouncer/userlist.txt: Contains plain text passwords
  - auth_type: SCRAM-SHA-256 (secure hash negotiation with PostgreSQL)
  - No TLS: Internal network only (not suitable for remote access)
  - Password authentication required via PGPASSWORD env var or connection string

For Production:
  - Add TLS/SSL layer
  - Enable PostgreSQL audit logging
  - Restrict port exposure
  - Use firewall rules
  - Enable authentication from application
```

## Performance Characteristics

### Connection Overhead
- **Direct PostgreSQL**: ~5-10ms per new connection
- **PgBouncer pooled**: ~< 1ms (from pool)
- **Network round-trip**: ~1-2ms typical

### Query Latency
- **Simple query**: 1-5ms (network + execution)
- **Complex query**: 50-500ms (depends on query)
- **Connection from pool**: Saves ~10ms per query

### Throughput
- **PgBouncer overhead**: <  5% of query time
- **Replication lag**: < 100ms typical
- **Failover time**: 20-30 seconds

## Scaling Considerations

### Scaling Out (More Replicas)
```
Currently: 1 Primary + 2 Replicas

Can add: pg-node-4, pg-node-5, etc.
Patroni will manage all automatically
Replication happens to all replicas

Trade-off: More replicas = more WAL shipping overhead, but
  - Better read distribution
  - Better failover options
  - Higher availability
```

### Scaling Up (Larger Instances)
```
Increase container resource limits:
  - More CPU → Faster query execution
  - More RAM → Larger working set, fewer disk I/Os
  - More disk → More data capacity

Tuning PgBouncer:
  - Increase default_pool_size for high concurrency
  - Increase max_client_conn for many connections
```

---

## Next Steps

- **[Diagrams & Workflows](DIAGRAMS.md)** - Visual flowcharts
- **[Operations](../guides/02-OPERATIONS.md)** - How to operate this
- **[Configuration](../reference/CONFIG-REFERENCE.md)** - Tuning options
- **[Troubleshooting](../guides/03-TROUBLESHOOTING.md)** - When things go wrong
