"""
Patroni HA Health Check DAG
============================
Polls the Patroni REST API on each PostgreSQL node and logs cluster topology.
Raises an alert (task failure) if no leader is found or replication lag is high.

Tasks:
  1. check_patroni_leader   — verify a leader exists via /leader on each node
  2. check_cluster_topology — log all member roles, lag, and timeline
  3. check_pgbouncer_pools  — verify PgBouncer connection pools via SHOW POOLS

Schedule: every 15 minutes (can be changed)
"""

from __future__ import annotations

import json
from datetime import timedelta

import requests

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.utils.dates import days_ago

PATRONI_NODES = [
    ("pg-node-1", 8008),
    ("pg-node-2", 8008),
    ("pg-node-3", 8008),
]
POSTGRES_CONN_ID = "postgres_ha"
LAG_WARNING_BYTES = 50 * 1024 * 1024  # 50 MB

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 1,
    "retry_delay": timedelta(seconds=15),
    "email_on_failure": False,
}


def check_patroni_leader(**ctx):
    leader = None
    for host, port in PATRONI_NODES:
        try:
            resp = requests.get(f"http://{host}:{port}/leader", timeout=5)
            if resp.status_code == 200:
                leader = host
                data = resp.json()
                print(f"Leader found: {host} — role={data.get('role')}, state={data.get('state')}")
                ctx["ti"].xcom_push(key="leader_host", value=host)
                ctx["ti"].xcom_push(key="leader_data", value=data)
                break
        except Exception as exc:
            print(f"  {host}:{port} — unreachable: {exc}")

    if leader is None:
        raise RuntimeError("No Patroni leader found across all nodes — cluster may be degraded!")


def check_cluster_topology(**ctx):
    # Query /cluster from any reachable node
    for host, port in PATRONI_NODES:
        try:
            resp = requests.get(f"http://{host}:{port}/cluster", timeout=5)
            if resp.status_code == 200:
                cluster = resp.json()
                members = cluster.get("members", [])
                print(f"Cluster topology ({len(members)} members):")
                lag_warning = False
                for m in members:
                    lag = m.get("lag", 0) or 0
                    role = m.get("role", "unknown")
                    state = m.get("state", "unknown")
                    timeline = m.get("timeline", "?")
                    print(f"  {m['name']:15s}  role={role:10s}  state={state:12s}  lag={lag:>10}  tl={timeline}")
                    if isinstance(lag, int) and lag > LAG_WARNING_BYTES:
                        print(f"  ⚠  WARNING: {m['name']} replication lag {lag} bytes > threshold {LAG_WARNING_BYTES}")
                        lag_warning = True
                if lag_warning:
                    raise RuntimeError("Replication lag exceeded threshold — check cluster health")
                return
        except RuntimeError:
            raise
        except Exception as exc:
            print(f"  {host}:{port} /cluster unreachable: {exc}")
    raise RuntimeError("Could not reach /cluster endpoint on any Patroni node")


def check_pgbouncer_pools(**ctx):
    hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)
    rows = hook.get_records("SHOW POOLS")
    print(f"PgBouncer pools ({len(rows)} entries):")
    for r in rows:
        # columns: database, user, cl_active, cl_waiting, sv_active, sv_idle, sv_used, sv_tested, sv_login, maxwait
        db = r[0] if len(r) > 0 else "?"
        user = r[1] if len(r) > 1 else "?"
        cl_active = r[2] if len(r) > 2 else 0
        sv_active = r[4] if len(r) > 4 else 0
        maxwait = r[9] if len(r) > 9 else 0
        print(f"  db={db:25s}  user={user:15s}  cl_active={cl_active}  sv_active={sv_active}  maxwait={maxwait}s")
        if maxwait and int(maxwait) > 10:
            raise RuntimeError(f"PgBouncer pool '{db}' maxwait={maxwait}s — client queue building up!")


with DAG(
    dag_id="postgres_ha_health_check",
    description="Monitors Patroni cluster topology and PgBouncer pool health",
    default_args=default_args,
    schedule_interval="*/15 * * * *",  # every 15 minutes
    start_date=days_ago(1),
    catchup=False,
    tags=["monitoring", "patroni", "ha", "pgbouncer"],
) as dag:

    t_leader = PythonOperator(
        task_id="check_patroni_leader",
        python_callable=check_patroni_leader,
    )

    t_topology = PythonOperator(
        task_id="check_cluster_topology",
        python_callable=check_cluster_topology,
    )

    t_pools = PythonOperator(
        task_id="check_pgbouncer_pools",
        python_callable=check_pgbouncer_pools,
    )

    t_leader >> t_topology >> t_pools
