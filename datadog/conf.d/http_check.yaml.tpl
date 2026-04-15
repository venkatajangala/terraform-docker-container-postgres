## Datadog HTTP check integration — rendered by Terraform
## Monitors Patroni REST API health endpoints on all three nodes.
## Uses /liveness which returns HTTP 200 regardless of role (primary or replica),
## so the check passes on every running node without false-positive alerts.

init_config:

instances:
  ## ─── Patroni node liveness probes ─────────────────────────────────────────
  ## /liveness → 200 if the Patroni process is alive (any role)
  - name: patroni-node-1-liveness
    url: http://pg-node-1:8008/liveness
    timeout: 5
    tags:
      - "service:patroni"
      - "node:pg-node-1"
      - "cluster:pg-ha-cluster"

  - name: patroni-node-2-liveness
    url: http://pg-node-2:8008/liveness
    timeout: 5
    tags:
      - "service:patroni"
      - "node:pg-node-2"
      - "cluster:pg-ha-cluster"

  - name: patroni-node-3-liveness
    url: http://pg-node-3:8008/liveness
    timeout: 5
    tags:
      - "service:patroni"
      - "node:pg-node-3"
      - "cluster:pg-ha-cluster"

  ## ─── Patroni cluster endpoint (full cluster JSON) ─────────────────────────
  ## Polls /cluster on node-1; returns cluster topology regardless of leader.
  - name: patroni-cluster-status
    url: http://pg-node-1:8008/cluster
    timeout: 5
    tags:
      - "service:patroni"
      - "check:cluster-topology"
      - "cluster:pg-ha-cluster"

  ## ─── etcd client health ───────────────────────────────────────────────────
  - name: etcd-health
    url: http://etcd:2379/health
    timeout: 5
    tags:
      - "service:etcd"
      - "cluster:pg-ha-cluster"

%{ if vault_enabled ~}
  ## ─── HashiCorp Vault health ────────────────────────────────────────────────
  ## /v1/sys/health → 200 when initialised + unsealed + active
  - name: vault-health
    url: http://vault:${vault_port}/v1/sys/health
    timeout: 5
    tags:
      - "service:vault"
      - "cluster:pg-ha-cluster"
%{ endif ~}
