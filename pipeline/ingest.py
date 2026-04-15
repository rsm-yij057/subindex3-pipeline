"""
ingest.py – Fetch data from external APIs and store raw responses in si3_raw_metrics.

Usage:
    python ingest.py                        # run all active sources
    python ingest.py --source-id 1          # run a single source
    python ingest.py --year 2024 --month 3  # pass extra params at runtime

Environment variables required:
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
    <API_KEY_ENV_VAR> as configured per row in api_source_config (if auth_type != 'none')
"""

import os
import json
import logging
import argparse
from datetime import datetime, timezone

import requests
import psycopg2
import psycopg2.extras

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db_connection():
    """Return a psycopg2 connection using environment variables."""
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", 5432),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


def fetch_active_sources(conn, source_id: int | None = None) -> list[dict]:
    """Return all active rows from api_source_config, optionally filtered."""
    query = """
        SELECT
            id,
            source_id,
            source_name,
            base_url,
            endpoint,
            http_method,
            auth_type,
            api_key_env_var,
            default_params,
            response_schema
        FROM api_source_config
        WHERE is_active = TRUE
    """
    params = []
    if source_id is not None:
        query += " AND id = %s"
        params.append(source_id)

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query, params)
        return [dict(row) for row in cur.fetchall()]


def insert_raw_payload(conn, source_id: int, api_source_id: int, payload: dict) -> int:
    """Write a raw JSON response to si3_raw_metrics; return the new row id."""
    query = """
        INSERT INTO si3_raw_metrics (source_id, api_source_id, raw_payload, ingested_at, ingestion_status)
        VALUES (%s, %s, %s, %s, 'pending')
        RETURNING id
    """
    with conn.cursor() as cur:
        cur.execute(
            query,
            (
                source_id,
                api_source_id,
                psycopg2.extras.Json(payload),
                datetime.now(timezone.utc),
            ),
        )
        row_id = cur.fetchone()[0]
    conn.commit()
    log.info("Stored raw payload → si3_raw_metrics id=%d", row_id)
    return row_id


def mark_raw_error(conn, raw_id: int, error_msg: str) -> None:
    """Flag a raw row as failed."""
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE si3_raw_metrics SET ingestion_status = 'error' WHERE id = %s",
            (raw_id,),
        )
    conn.commit()
    log.warning("Marked si3_raw_metrics id=%d as error: %s", raw_id, error_msg)


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def build_headers(source: dict) -> dict:
    """
    Construct request headers.
    For api_key auth the key is read from the environment variable named in
    source['api_key_env_var'] – the actual value is never stored in the DB.
    """
    headers = {"Accept": "application/json"}

    if source["auth_type"] == "api_key":
        env_var = source["api_key_env_var"]
        if not env_var:
            raise ValueError(f"auth_type is 'api_key' but api_key_env_var is NULL for source {source['id']}")
        api_key = os.environ.get(env_var)
        if not api_key:
            raise EnvironmentError(f"Environment variable '{env_var}' is not set")
        headers["X-API-Key"] = api_key

    elif source["auth_type"] == "bearer":
        env_var = source["api_key_env_var"]
        token = os.environ.get(env_var, "")
        if not token:
            raise EnvironmentError(f"Environment variable '{env_var}' is not set")
        headers["Authorization"] = f"Bearer {token}"

    return headers


def call_api(source: dict, extra_params: dict | None = None) -> dict:
    """
    Make the HTTP request described by *source* and return the parsed JSON body.
    extra_params (e.g. {"year": 2024, "month": 3}) are merged with default_params.
    """
    url = source["base_url"].rstrip("/") + "/" + source["endpoint"].lstrip("/")
    params = {**source["default_params"], **(extra_params or {})}
    headers = build_headers(source)

    log.info("Calling %s %s (params=%s)", source["http_method"], url, params)

    response = requests.request(
        method=source["http_method"],
        url=url,
        headers=headers,
        params=params if source["http_method"] == "GET" else None,
        json=params if source["http_method"] == "POST" else None,
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


# ---------------------------------------------------------------------------
# Main ingestion loop
# ---------------------------------------------------------------------------

def run_ingestion(source_id: int | None = None, extra_params: dict | None = None) -> None:
    conn = get_db_connection()
    try:
        sources = fetch_active_sources(conn, source_id)
        if not sources:
            log.warning("No active sources found (source_id filter=%s)", source_id)
            return

        for source in sources:
            log.info("--- Processing source: %s (id=%d) ---", source["source_name"], source["id"])
            raw_id = None
            try:
                payload = call_api(source, extra_params)
                raw_id = insert_raw_payload(conn, source["source_id"], source["id"], payload)
                log.info("Ingestion complete for '%s'", source["source_name"])

            except requests.HTTPError as exc:
                log.error("HTTP error for source %d: %s", source["id"], exc)
                if raw_id is not None:
                    mark_raw_error(conn, raw_id, str(exc))

            except Exception as exc:
                log.error("Unexpected error for source %d: %s", source["id"], exc, exc_info=True)
                if raw_id is not None:
                    mark_raw_error(conn, raw_id, str(exc))

    finally:
        conn.close()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Ingest data from configured API sources.")
    parser.add_argument("--source-id", type=int, default=None, help="Run a specific api_source_config row")
    parser.add_argument("--year",       type=int, default=None, help="Year to pass as API param")
    parser.add_argument("--month",      type=int, default=None, help="Month (1–12) to pass as API param")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    extra = {}
    if args.year:
        extra["year"] = args.year
    if args.month:
        extra["month"] = args.month

    run_ingestion(source_id=args.source_id, extra_params=extra or None)
