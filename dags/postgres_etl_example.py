"""
ETL Example DAG — PostgreSQL HA Cluster
========================================
Demonstrates reading from and writing to the HA PostgreSQL cluster via
PgBouncer (connection ID: postgres_ha, injected via AIRFLOW_CONN_POSTGRES_HA).

Tasks:
  1. check_connection    — verify PgBouncer + HA cluster reachability
  2. extract_audit_logs  — read recent audit_log rows
  3. transform           — count by action and compute stats (in-memory)
  4. load_summary        — write summary to a staging table
  5. verify_load         — confirm the row count landed correctly

Schedule: manual (not paused — enable via UI or unpause_dag_on_creation=True)
"""

from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.utils.dates import days_ago

POSTGRES_CONN_ID = "postgres_ha"  # injected via AIRFLOW_CONN_POSTGRES_HA env var

default_args = {
    "owner": "airflow",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(seconds=30),
    "email_on_failure": False,
}


def check_connection(**ctx):
    hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)
    result = hook.get_first("SELECT version(), pg_is_in_recovery()")
    version, is_replica = result
    print(f"Connected to: {version}")
    print(f"Is replica: {is_replica}")
    if is_replica:
        raise RuntimeError("ETL DAG landed on a replica — check PgBouncer routing")
    ctx["ti"].xcom_push(key="pg_version", value=str(version))


def extract_audit_logs(**ctx):
    hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)
    rows = hook.get_records("""
        SELECT action, COUNT(*) AS cnt
        FROM audit.audit_log
        WHERE created_at >= NOW() - INTERVAL '7 days'
        GROUP BY action
        ORDER BY cnt DESC
        LIMIT 100
    """)
    print(f"Extracted {len(rows)} action-groups from audit_log")
    # Push as list-of-dicts for the transform step
    data = [{"action": r[0], "cnt": r[1]} for r in rows]
    ctx["ti"].xcom_push(key="audit_summary", value=data)
    return len(rows)


def transform(**ctx):
    data = ctx["ti"].xcom_pull(key="audit_summary", task_ids="extract_audit_logs") or []
    total = sum(r["cnt"] for r in data)
    result = {
        "total_events": total,
        "unique_actions": len(data),
        "top_action": data[0]["action"] if data else "none",
        "top_action_count": data[0]["cnt"] if data else 0,
        "computed_at": datetime.utcnow().isoformat(),
    }
    print(f"Transform result: {result}")
    ctx["ti"].xcom_push(key="transformed", value=result)
    return result


def load_summary(**ctx):
    result = ctx["ti"].xcom_pull(key="transformed", task_ids="transform")
    hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    # Create staging table if needed (idempotent)
    hook.run("""
        CREATE TABLE IF NOT EXISTS etl_audit_summary (
            id              SERIAL PRIMARY KEY,
            run_date        TIMESTAMPTZ DEFAULT NOW(),
            total_events    BIGINT,
            unique_actions  INT,
            top_action      TEXT,
            top_action_count BIGINT
        )
    """)

    hook.run(
        """
        INSERT INTO etl_audit_summary (total_events, unique_actions, top_action, top_action_count)
        VALUES (%s, %s, %s, %s)
        """,
        parameters=(
            result["total_events"],
            result["unique_actions"],
            result["top_action"],
            result["top_action_count"],
        ),
    )
    print(f"Loaded summary row: {result}")


def verify_load(**ctx):
    hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)
    count = hook.get_first("SELECT COUNT(*) FROM etl_audit_summary")[0]
    print(f"etl_audit_summary now has {count} row(s)")
    assert count > 0, "Load verification failed: no rows in etl_audit_summary"


with DAG(
    dag_id="postgres_etl_example",
    description="ETL example: audit_log → transform → summary table via HA PgBouncer",
    default_args=default_args,
    schedule_interval=None,  # trigger manually or via API
    start_date=days_ago(1),
    catchup=False,
    tags=["etl", "postgres", "ha", "example"],
) as dag:

    t_check = PythonOperator(
        task_id="check_connection",
        python_callable=check_connection,
    )

    t_extract = PythonOperator(
        task_id="extract_audit_logs",
        python_callable=extract_audit_logs,
    )

    t_transform = PythonOperator(
        task_id="transform",
        python_callable=transform,
    )

    t_load = PythonOperator(
        task_id="load_summary",
        python_callable=load_summary,
    )

    t_verify = PythonOperator(
        task_id="verify_load",
        python_callable=verify_load,
    )

    t_check >> t_extract >> t_transform >> t_load >> t_verify
