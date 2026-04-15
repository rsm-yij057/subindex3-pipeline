"""
transform.py – Light transformation layer: raw JSON → si3_monthly_metrics.

Responsibilities (no heavy aggregation – USGS already provides monthly totals):
    1. Load pending rows from si3_raw_metrics
    2. Normalize field names and date format
    3. Validate required fields
    4. Map country / mineral / metric names to internal IDs
    5. Write to si3_monthly_metrics
    6. Mark raw rows as 'transformed'

Usage:
    python transform.py                 # process all pending raw rows
    python transform.py --raw-id 42    # process a single raw row
"""

import os
import logging
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras

log = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)


# ---------------------------------------------------------------------------
# Database connection (reuses same env vars as ingest.py)
# ---------------------------------------------------------------------------

def get_db_connection():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", 5432),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


# ---------------------------------------------------------------------------
# ID-lookup helpers (cached per run to avoid N+1 queries)
# ---------------------------------------------------------------------------

def load_lookup(conn, table: str, name_col: str, id_col: str) -> dict[str, int]:
    """Return {lowercase_name: id} mapping for a dimension table."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT {id_col}, {name_col} FROM {table}")
        return {row[1].lower(): row[0] for row in cur.fetchall()}


def build_lookups(conn) -> dict:
    return {
        "countries":  load_lookup(conn, "si3_countries",          "country_name",  "country_id"),
        "minerals":   load_lookup(conn, "si3_mineral_codes",       "mineral_name",  "mineral_id"),
        "metrics":    load_lookup(conn, "si3_metric_definitions",  "metric_name",   "metric_id"),
    }


# ---------------------------------------------------------------------------
# Normalization helpers
# ---------------------------------------------------------------------------

# Map common USGS field names → internal standard names
FIELD_ALIASES: dict[str, str] = {
    "Country":        "country",
    "country_name":   "country",
    "Mineral":        "mineral",
    "commodity":      "mineral",
    "Commodity":      "mineral",
    "Period":         "period",
    "period_date":    "period",
    "Value":          "value",
    "amount":         "value",
    "metric":         "metric",
    "MetricType":     "metric",
    "unit":           "unit",
    "Unit":           "unit",
}

REQUIRED_FIELDS = {"country", "mineral", "metric", "period", "value"}


def normalize_record(raw: dict) -> dict:
    """
    Apply field aliases so downstream code always sees consistent key names.
    Returns a new dict; does not mutate the input.
    """
    normalized = {}
    for key, val in raw.items():
        standard_key = FIELD_ALIASES.get(key, key.lower())
        normalized[standard_key] = val
    return normalized


def parse_period(period_str: str) -> str:
    """
    Accept common date strings and return YYYY-MM-01 (first of month).

    Handles: "2024-03", "2024-03-01", "March 2024", "03/2024"
    """
    period_str = str(period_str).strip()
    for fmt in ("%Y-%m-%d", "%Y-%m", "%B %Y", "%m/%Y"):
        try:
            dt = datetime.strptime(period_str, fmt)
            return dt.strftime("%Y-%m-01")
        except ValueError:
            continue
    raise ValueError(f"Cannot parse period: {period_str!r}")


def validate_record(record: dict) -> list[str]:
    """Return a list of validation error messages (empty = valid)."""
    errors = []
    for field in REQUIRED_FIELDS:
        if field not in record or record[field] is None or str(record[field]).strip() == "":
            errors.append(f"Missing required field: '{field}'")
    try:
        float(record.get("value", ""))
    except (ValueError, TypeError):
        errors.append(f"Non-numeric value: {record.get('value')!r}")
    return errors


# ---------------------------------------------------------------------------
# Core transformation logic
# ---------------------------------------------------------------------------

def extract_records(payload: dict, response_schema: dict) -> list[dict]:
    """
    Navigate the raw JSON payload using response_schema to find the list of
    data records.

    response_schema examples:
        {"type": "json_array"}                          → payload is the list
        {"type": "json_object", "data_key": "results"} → payload["results"] is the list
    """
    schema_type = response_schema.get("type", "json_array")
    if schema_type == "json_array":
        if isinstance(payload, list):
            return payload
        raise ValueError("Expected a JSON array at the top level")
    elif schema_type == "json_object":
        data_key = response_schema.get("data_key")
        if not data_key or data_key not in payload:
            raise ValueError(f"data_key '{data_key}' not found in response")
        return payload[data_key]
    else:
        raise ValueError(f"Unknown response schema type: {schema_type!r}")


def transform_raw_row(conn, raw_row: dict, lookups: dict) -> list[dict]:
    """
    Convert one si3_raw_metrics row into a list of dicts ready for
    si3_monthly_metrics insertion.
    """
    payload         = raw_row["raw_payload"]
    api_source_id   = raw_row["api_source_id"]
    source_id       = raw_row["source_id"]
    response_schema = raw_row["response_schema"] or {}

    records = extract_records(payload, response_schema)
    transformed = []

    for raw_record in records:
        rec = normalize_record(raw_record)

        # Validate
        errors = validate_record(rec)
        if errors:
            log.warning("Skipping record %s – %s", raw_record, "; ".join(errors))
            continue

        # Map dimension names → internal IDs
        country_id = lookups["countries"].get(rec["country"].lower())
        mineral_id = lookups["minerals"].get(rec["mineral"].lower())
        metric_id  = lookups["metrics"].get(rec["metric"].lower())

        if None in (country_id, mineral_id, metric_id):
            log.warning(
                "Skipping record – unmapped dimension: country=%r mineral=%r metric=%r",
                rec["country"], rec["mineral"], rec["metric"],
            )
            continue

        # Normalize period
        try:
            period = parse_period(rec["period"])
        except ValueError as exc:
            log.warning("Skipping record – %s", exc)
            continue

        transformed.append({
            "source_id":      source_id,
            "api_source_id":  api_source_id,
            "country_id":     country_id,
            "mineral_id":     mineral_id,
            "metric_id":      metric_id,
            "period":         period,
            "value":          float(rec["value"]),
            "unit":           rec.get("unit"),
            "load_timestamp": datetime.now(timezone.utc),
        })

    return transformed


def insert_monthly_metrics(conn, records: list[dict]) -> int:
    """Bulk-insert into si3_monthly_metrics; return count inserted."""
    if not records:
        return 0

    query = """
        INSERT INTO si3_monthly_metrics
            (source_id, country_id, mineral_id, metric_id, period, value, unit, load_timestamp)
        VALUES
            (%(source_id)s, %(country_id)s, %(mineral_id)s, %(metric_id)s,
             %(period)s, %(value)s, %(unit)s, %(load_timestamp)s)
        ON CONFLICT DO NOTHING
    """
    with conn.cursor() as cur:
        psycopg2.extras.execute_batch(cur, query, records)
    conn.commit()
    return len(records)


def mark_transformed(conn, raw_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE si3_raw_metrics SET ingestion_status = 'transformed' WHERE id = %s",
            (raw_id,),
        )
    conn.commit()


# ---------------------------------------------------------------------------
# Fetch pending raw rows
# ---------------------------------------------------------------------------

def fetch_pending_raw_rows(conn, raw_id: int | None = None) -> list[dict]:
    query = """
        SELECT
            r.id,
            r.source_id,
            r.api_source_id,
            r.raw_payload,
            r.ingested_at,
            c.response_schema
        FROM si3_raw_metrics       r
        JOIN api_source_config     c ON c.id = r.api_source_id
        WHERE r.ingestion_status = 'pending'
    """
    params = []
    if raw_id is not None:
        query += " AND r.id = %s"
        params.append(raw_id)

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query, params)
        return [dict(row) for row in cur.fetchall()]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_transform(raw_id: int | None = None) -> None:
    conn = get_db_connection()
    try:
        lookups   = build_lookups(conn)
        raw_rows  = fetch_pending_raw_rows(conn, raw_id)

        if not raw_rows:
            log.info("No pending raw rows to transform.")
            return

        log.info("Found %d pending raw row(s).", len(raw_rows))
        total_inserted = 0

        for raw_row in raw_rows:
            log.info("Transforming si3_raw_metrics id=%d", raw_row["id"])
            try:
                records  = transform_raw_row(conn, raw_row, lookups)
                inserted = insert_monthly_metrics(conn, records)
                total_inserted += inserted
                mark_transformed(conn, raw_row["id"])
                log.info("  → %d record(s) written to si3_monthly_metrics", inserted)
            except Exception as exc:
                log.error("  Error transforming raw id=%d: %s", raw_row["id"], exc, exc_info=True)

        log.info("Transform complete. Total records inserted: %d", total_inserted)
    finally:
        conn.close()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Transform pending raw API payloads into monthly metrics.")
    parser.add_argument("--raw-id", type=int, default=None, help="Process a single si3_raw_metrics row")
    args = parser.parse_args()
    run_transform(raw_id=args.raw_id)
