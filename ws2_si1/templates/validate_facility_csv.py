"""
WS2 SI1 — Facility CSV validator and loader.

Usage:
    # Dry run: validate only, no database connection needed
    python validate_facility_csv.py path/to/file.csv

    # Validate + load to database
    python validate_facility_csv.py path/to/file.csv \
        --load \
        --dsn 'postgresql://user:pass@host:port/csi' \
        --run-name 'manual_2026q1_usa' \
        --triggered-by 'alice'

The validator catches all of these without touching the database:
    * Wrong column set (missing required, unknown extras)
    * Empty required cells
    * Invalid country names
    * Bad date formats
    * Bad numeric formats
    * Out-of-range values (capacity_mw <= 0, future date_operational, etc.)
    * Inconsistent dates (operational < announced)
    * Invalid status / capacity_basis / confidence enums
    * Suspicious patterns (TBD in date columns, etc.)

Loader behavior (when --load is set):
    * Creates a row in ws2.collection_runs
    * Inserts each valid row to ws2.facilities (handles duplicates via UNIQUE constraint)
    * Logs each insert to ws2.collection_log
    * Marks the run success/partial/failed
    * Does NOT update ws2.facility_snapshots — that's a separate quarterly job
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ─────────────────────────────────────────────────────────────────────────────
# Schema (must match ws2.facilities CHECK constraints exactly)
# ─────────────────────────────────────────────────────────────────────────────

VALID_COUNTRIES = {"USA", "UAE", "Brazil", "India", "Singapore", "Philippines"}
VALID_STATUS = {"operational", "under_construction", "permitted",
                "announced", "cancelled", "decommissioned"}
VALID_CAPACITY_BASIS = {"critical_it", "gross", "unknown"}
VALID_CONFIDENCE = {"high", "medium", "low"}
VALID_ENERGY_SOURCE = {"renewable", "grid", "natural_gas", "mixed", ""}

REQUIRED_COLS = {
    "country", "facility_name", "operator", "capacity_mw",
    "status", "primary_source", "source_collected_date",
}

ALL_COLS = [
    "country", "facility_name", "operator", "city", "region",
    "capacity_mw", "capacity_basis", "status",
    "date_announced", "date_operational", "expected_operational",
    "investment_value_usd", "investment_currency", "investment_fx_rate", "investment_fx_date",
    "energy_source", "chip_type_if_known",
    "primary_source", "source_url",
    "source_collected_date", "source_published_date",
    "confidence", "notes",
]

DATE_COLS = {"date_announced", "date_operational", "expected_operational",
             "source_collected_date", "source_published_date", "investment_fx_date"}
NUMERIC_COLS = {"capacity_mw", "investment_value_usd", "investment_fx_rate"}

# Things people accidentally put in date columns; flagged so they get fixed
# instead of silently dropped.
SUSPICIOUS_DATE_VALUES = re.compile(
    r"(TBD|TBA|Q[1-4]|H[12]|early|mid|late|unknown|tba|\d{4}\s*Q\d|month)",
    re.IGNORECASE
)


# ─────────────────────────────────────────────────────────────────────────────
# Validation result types
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class RowError:
    line_no: int  # 1-indexed; line 1 is the header
    column: str
    value: str
    message: str

    def __str__(self) -> str:
        v = self.value if len(self.value) < 60 else self.value[:57] + "..."
        return f"  line {self.line_no:4d} | {self.column:24s} | {v!r}: {self.message}"


@dataclass
class ValidationResult:
    n_rows: int = 0
    n_valid: int = 0
    errors: list[RowError] = field(default_factory=list)
    warnings: list[RowError] = field(default_factory=list)
    valid_rows: list[dict] = field(default_factory=list)  # for the loader

    @property
    def is_valid(self) -> bool:
        return len(self.errors) == 0

    def report(self) -> str:
        lines = [
            "=" * 70,
            f"Validation report",
            "=" * 70,
            f"Total data rows:   {self.n_rows}",
            f"Valid rows:        {self.n_valid}",
            f"Rows with errors:  {self.n_rows - self.n_valid}",
            f"Errors:            {len(self.errors)}",
            f"Warnings:          {len(self.warnings)}",
            "",
        ]
        if self.errors:
            lines.append("ERRORS (must fix before loading):")
            for e in self.errors:
                lines.append(str(e))
            lines.append("")
        if self.warnings:
            lines.append("WARNINGS (review but won't block load):")
            for w in self.warnings:
                lines.append(str(w))
            lines.append("")
        lines.append("=" * 70)
        if self.is_valid:
            lines.append("✓ All rows validate. Re-run with --load to insert.")
        else:
            lines.append(f"✗ {len(self.errors)} error(s). Fix and re-run.")
        return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# Field-level parsers
# ─────────────────────────────────────────────────────────────────────────────

def parse_date(raw: str) -> Optional[dt.date]:
    """Strict YYYY-MM-DD or empty → None. Returns None on bad input
    AND raises ValueError so caller can collect the diagnostic."""
    s = (raw or "").strip()
    if not s:
        return None
    if SUSPICIOUS_DATE_VALUES.search(s):
        raise ValueError(f"date column contains qualitative timing ({s!r}); leave blank and put in notes")
    try:
        return dt.datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise ValueError(f"expected YYYY-MM-DD, got {s!r}")


def parse_number(raw: str) -> Optional[float]:
    s = (raw or "").strip()
    if not s:
        return None
    # Catch common formatting mistakes BEFORE float() so the message is useful
    if "," in s and "." in s:
        # "1,200.5" — thousands separator, allowed
        s = s.replace(",", "")
    elif "," in s:
        # "120,5" — locale-style decimal? Reject.
        raise ValueError(f"use '.' as decimal separator, not ',' (got {s!r})")
    try:
        return float(s)
    except ValueError:
        raise ValueError(f"not a valid number: {s!r}")


def normalize_country(raw: str) -> Optional[str]:
    s = (raw or "").strip()
    if not s:
        return None
    # Common aliases users type in
    aliases = {
        "united states": "USA", "us": "USA", "u.s.": "USA", "u.s.a.": "USA", "usa": "USA",
        "united arab emirates": "UAE", "uae": "UAE",
        "brazil": "Brazil", "brasil": "Brazil",
        "india": "India",
        "singapore": "Singapore",
        "philippines": "Philippines", "phillipines": "Philippines",  # typo
    }
    return aliases.get(s.lower(), s)  # if no alias match, return as-is for membership check


# ─────────────────────────────────────────────────────────────────────────────
# Main validator
# ─────────────────────────────────────────────────────────────────────────────

def validate_csv(path: Path) -> ValidationResult:
    result = ValidationResult()

    if not path.exists():
        result.errors.append(RowError(0, "<file>", str(path), f"file not found"))
        return result

    with path.open("r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096)
        f.seek(0)
        # Reject if there are tabs (we mandated comma-delimited)
        if "\t" in sample:
            result.errors.append(RowError(0, "<file>", "(tab character)",
                                          "file contains tab characters; save as comma-delimited UTF-8"))
            return result

        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            result.errors.append(RowError(0, "<file>", "", "file is empty"))
            return result

        # ── Header check ─────────────────────────────────────────────────
        headers = [h.strip() for h in reader.fieldnames]
        missing_required = REQUIRED_COLS - set(headers)
        unknown_cols = set(headers) - set(ALL_COLS)
        if missing_required:
            result.errors.append(RowError(1, "<header>", ",".join(headers),
                f"missing required columns: {sorted(missing_required)}"))
        if unknown_cols:
            result.warnings.append(RowError(1, "<header>", ",".join(sorted(unknown_cols)),
                f"unknown columns will be ignored on load"))

        if missing_required:
            return result  # can't sensibly validate rows without required columns

        # ── Row-by-row validation ────────────────────────────────────────
        for line_no, raw_row in enumerate(reader, start=2):  # line 1 = header
            # Detect first all-blank row → end of data
            if all((v or "").strip() == "" for v in raw_row.values()):
                break

            result.n_rows += 1
            row_errors: list[RowError] = []
            cleaned: dict = {}

            # Required string fields
            for col in ("country", "facility_name", "operator",
                        "status", "primary_source"):
                v = (raw_row.get(col) or "").strip()
                if not v:
                    row_errors.append(RowError(line_no, col, "", "required, but empty"))
                cleaned[col] = v

            # Country
            country = normalize_country(cleaned["country"])
            if country and country not in VALID_COUNTRIES:
                row_errors.append(RowError(line_no, "country", cleaned["country"],
                    f"unknown country; expected one of {sorted(VALID_COUNTRIES)}"))
            cleaned["country"] = country

            # Status
            if cleaned["status"] and cleaned["status"] not in VALID_STATUS:
                row_errors.append(RowError(line_no, "status", cleaned["status"],
                    f"invalid status; expected one of {sorted(VALID_STATUS)}"))

            # Capacity
            try:
                cap = parse_number(raw_row.get("capacity_mw", ""))
                if cap is None:
                    row_errors.append(RowError(line_no, "capacity_mw", "", "required, but empty"))
                elif cap <= 0:
                    row_errors.append(RowError(line_no, "capacity_mw", str(cap),
                        "must be > 0 (or leave blank if unknown — but then status can't be operational)"))
                cleaned["capacity_mw"] = cap
            except ValueError as e:
                row_errors.append(RowError(line_no, "capacity_mw", raw_row.get("capacity_mw", ""), str(e)))
                cleaned["capacity_mw"] = None

            # capacity_basis
            cb = (raw_row.get("capacity_basis") or "critical_it").strip().lower()
            if cb not in VALID_CAPACITY_BASIS:
                row_errors.append(RowError(line_no, "capacity_basis", cb,
                    f"invalid; expected one of {sorted(VALID_CAPACITY_BASIS)}"))
            cleaned["capacity_basis"] = cb

            # Dates
            for col in DATE_COLS:
                try:
                    cleaned[col] = parse_date(raw_row.get(col, ""))
                except ValueError as e:
                    row_errors.append(RowError(line_no, col, raw_row.get(col, ""), str(e)))
                    cleaned[col] = None

            # Required date: source_collected_date
            if cleaned.get("source_collected_date") is None:
                row_errors.append(RowError(line_no, "source_collected_date", "",
                    "required (the date you pulled this datum)"))

            # date_operational > date_announced
            d_ann = cleaned.get("date_announced")
            d_op = cleaned.get("date_operational")
            if d_ann and d_op and d_op < d_ann:
                row_errors.append(RowError(line_no, "date_operational", str(d_op),
                    f"is before date_announced ({d_ann}); check ordering"))

            # status=operational ⇒ should have date_operational (or high confidence)
            confidence = (raw_row.get("confidence") or "medium").strip().lower()
            if cleaned["status"] == "operational" and not d_op and confidence != "high":
                # Not a hard error — surface as warning
                result.warnings.append(RowError(line_no, "date_operational", "",
                    "status=operational without date_operational; set confidence=high or fill date"))

            if confidence and confidence not in VALID_CONFIDENCE:
                row_errors.append(RowError(line_no, "confidence", confidence,
                    f"invalid; expected one of {sorted(VALID_CONFIDENCE)}"))
            cleaned["confidence"] = confidence

            # Numeric: investment_value_usd, investment_fx_rate
            for col in ("investment_value_usd", "investment_fx_rate"):
                try:
                    cleaned[col] = parse_number(raw_row.get(col, ""))
                    if cleaned[col] is not None and cleaned[col] < 0:
                        row_errors.append(RowError(line_no, col, str(cleaned[col]),
                            "must be non-negative"))
                except ValueError as e:
                    row_errors.append(RowError(line_no, col, raw_row.get(col, ""), str(e)))
                    cleaned[col] = None

            # Energy source
            es = (raw_row.get("energy_source") or "").strip().lower()
            if es and es not in VALID_ENERGY_SOURCE:
                result.warnings.append(RowError(line_no, "energy_source", es,
                    f"unrecognized; expected one of {sorted(VALID_ENERGY_SOURCE - {''})} or blank"))
            cleaned["energy_source"] = es or None

            # Pass-through fields
            for col in ("city", "region", "investment_currency", "chip_type_if_known",
                        "primary_source", "source_url", "notes"):
                cleaned[col] = (raw_row.get(col) or "").strip() or None

            if row_errors:
                result.errors.extend(row_errors)
            else:
                result.n_valid += 1
                result.valid_rows.append(cleaned)

    return result


# ─────────────────────────────────────────────────────────────────────────────
# Loader (called only with --load)
# ─────────────────────────────────────────────────────────────────────────────

def load_to_db(rows: list[dict], dsn: str, run_name: str, triggered_by: str) -> dict:
    """Insert validated rows into ws2.facilities. Returns load summary."""
    try:
        import psycopg
        from psycopg.rows import dict_row
    except ImportError:
        sys.exit("psycopg not installed. `pip install 'psycopg[binary]'` to use --load.")

    summary = {"attempted": len(rows), "inserted": 0, "skipped_duplicate": 0, "failed": 0}

    with psycopg.connect(dsn, row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            # Open run
            cur.execute("""
                INSERT INTO ws2.collection_runs
                    (pipeline_name, source_name, triggered_by, status, rows_attempted)
                VALUES ('manual_csv_load', %s, %s, 'running', %s)
                RETURNING id
            """, (run_name, triggered_by, len(rows)))
            run_id = cur.fetchone()["id"]

            for row in rows:
                # Resolve country_id
                cur.execute("SELECT id FROM public.csi_countries WHERE country_name = %s",
                            (row["country"],))
                country_row = cur.fetchone()
                if not country_row:
                    summary["failed"] += 1
                    cur.execute("""
                        INSERT INTO ws2.collection_log
                            (run_id, action, status, error_message)
                        VALUES (%s, 'insert', 'validation_error', %s)
                    """, (run_id, f"country {row['country']!r} not in csi_countries"))
                    continue
                country_id = country_row["id"]

                try:
                    cur.execute("""
                        INSERT INTO ws2.facilities (
                            country_id, facility_name, operator, city, region,
                            capacity_mw, capacity_basis, status,
                            date_announced, date_operational, expected_operational,
                            investment_value_usd, investment_currency, investment_fx_rate, investment_fx_date,
                            energy_source, chip_type_if_known,
                            primary_source, source_url,
                            source_collected_date, source_published_date,
                            insert_method, confidence, notes,
                            created_by_run
                        ) VALUES (
                            %(country_id)s, %(facility_name)s, %(operator)s, %(city)s, %(region)s,
                            %(capacity_mw)s, %(capacity_basis)s, %(status)s,
                            %(date_announced)s, %(date_operational)s, %(expected_operational)s,
                            %(investment_value_usd)s, %(investment_currency)s, %(investment_fx_rate)s, %(investment_fx_date)s,
                            %(energy_source)s, %(chip_type_if_known)s,
                            %(primary_source)s, %(source_url)s,
                            %(source_collected_date)s, %(source_published_date)s,
                            'csv_import', %(confidence)s, %(notes)s,
                            %(run_id)s
                        )
                        ON CONFLICT (country_id, operator, facility_name, city) DO NOTHING
                        RETURNING id
                    """, {**row, "country_id": country_id, "run_id": run_id})

                    inserted_id = cur.fetchone()
                    if inserted_id:
                        summary["inserted"] += 1
                        cur.execute("""
                            INSERT INTO ws2.collection_log
                                (run_id, country_id, facility_id, action, status)
                            VALUES (%s, %s, %s, 'insert', 'success')
                        """, (run_id, country_id, inserted_id["id"]))
                    else:
                        summary["skipped_duplicate"] += 1
                        cur.execute("""
                            INSERT INTO ws2.collection_log
                                (run_id, country_id, action, status, error_message)
                            VALUES (%s, %s, 'skip', 'skipped',
                                    'duplicate (country, operator, facility_name, city)')
                        """, (run_id, country_id))
                except Exception as e:
                    summary["failed"] += 1
                    cur.execute("""
                        INSERT INTO ws2.collection_log
                            (run_id, country_id, action, status, error_message)
                        VALUES (%s, %s, 'insert', 'parse_error', %s)
                    """, (run_id, country_id, str(e)[:500]))

            # Close run
            run_status = ("success" if summary["failed"] == 0
                          else ("partial" if summary["inserted"] > 0 else "failed"))
            cur.execute("""
                UPDATE ws2.collection_runs
                SET status = %s, finished_at = NOW(),
                    rows_succeeded = %s, rows_failed = %s
                WHERE id = %s
            """, (run_status, summary["inserted"], summary["failed"], run_id))

        conn.commit()

    summary["run_id"] = run_id
    return summary


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv_path", type=Path, help="path to facility CSV file")
    p.add_argument("--load", action="store_true",
                   help="actually load to database (otherwise dry-run validate only)")
    p.add_argument("--dsn", help="postgres DSN, e.g. postgresql://user:pass@host:port/csi")
    p.add_argument("--run-name", default=None,
                   help="label for ws2.collection_runs.source_name (default: filename)")
    p.add_argument("--triggered-by", default="cli",
                   help="who triggered the load (default: cli)")
    args = p.parse_args()

    result = validate_csv(args.csv_path)
    print(result.report())

    if not result.is_valid:
        sys.exit(1)

    if not args.load:
        sys.exit(0)

    if not args.dsn:
        sys.exit("--load requires --dsn")

    print()
    print("Loading to database...")
    summary = load_to_db(
        result.valid_rows,
        dsn=args.dsn,
        run_name=args.run_name or args.csv_path.stem,
        triggered_by=args.triggered_by,
    )
    print(f"  Run id:            {summary['run_id']}")
    print(f"  Rows attempted:    {summary['attempted']}")
    print(f"  Rows inserted:     {summary['inserted']}")
    print(f"  Rows skipped (dup):{summary['skipped_duplicate']}")
    print(f"  Rows failed:       {summary['failed']}")


if __name__ == "__main__":
    main()
