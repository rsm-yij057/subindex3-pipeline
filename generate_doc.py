"""
generate_doc.py  –  Produces subindex_pipeline_design.docx
"""

from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.oxml import OxmlElement
import copy

OUT_PATH = "subindex_pipeline_design.docx"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def add_heading(doc, text, level=1):
    h = doc.add_heading(text, level=level)
    h.paragraph_format.space_before = Pt(12)
    h.paragraph_format.space_after  = Pt(4)
    return h


def add_body(doc, text):
    p = doc.add_paragraph(text)
    p.paragraph_format.space_after = Pt(6)
    return p


def add_code(doc, code_text):
    """Monospaced light-grey block for code / SQL / JSON examples."""
    p = doc.add_paragraph()
    p.paragraph_format.left_indent  = Inches(0.3)
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after  = Pt(4)

    # Light-grey shading on the paragraph
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"),   "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"),  "F0F0F0")
    pPr.append(shd)

    run = p.add_run(code_text)
    run.font.name = "Courier New"
    run.font.size = Pt(9)
    return p


def add_table(doc, headers, rows):
    table = doc.add_table(rows=1 + len(rows), cols=len(headers))
    table.style = "Table Grid"

    # Header row
    hdr = table.rows[0]
    for i, h in enumerate(headers):
        cell = hdr.cells[i]
        cell.text = h
        run = cell.paragraphs[0].runs[0]
        run.bold = True
        run.font.size = Pt(10)

    # Data rows
    for r_idx, row in enumerate(rows):
        for c_idx, val in enumerate(row):
            cell = table.rows[r_idx + 1].cells[c_idx]
            cell.text = str(val)
            cell.paragraphs[0].runs[0].font.size = Pt(9)

    doc.add_paragraph()   # spacing after table
    return table


# ---------------------------------------------------------------------------
# Document content
# ---------------------------------------------------------------------------

def build(doc):
    # ── Title ─────────────────────────────────────────────────────────────
    title = doc.add_heading("Subindex 3 – API Data Pipeline Design", 0)
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    sub = doc.add_paragraph("Database: subindex_3   |   Stack: PostgreSQL · Python · USGS API")
    sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    sub.paragraph_format.space_after = Pt(16)

    # ── File Locations ─────────────────────────────────────────────────────
    add_heading(doc, "File Locations", 1)
    add_body(doc,
        "All generated files live under myproject/subindex_pipeline/ "
        "in the project root.")
    add_code(doc,
        "myproject/subindex_pipeline/\n"
        "├── schema/\n"
        "│   └── api_pipeline.sql       ← DDL: table, migrations, indexes, seed row\n"
        "└── pipeline/\n"
        "    ├── ingest.py              ← Fetch from API → si3_raw_metrics\n"
        "    └── transform.py           ← si3_raw_metrics → si3_monthly_metrics")

    # ── 1. Pipeline Overview ───────────────────────────────────────────────
    add_heading(doc, "1. Pipeline Overview", 1)
    add_body(doc,
        "The pipeline follows a straightforward four-stage flow. "
        "USGS already publishes data at monthly granularity, so no "
        "time-aggregation is needed. The stages are:")
    add_code(doc,
        "USGS API\n"
        "   │\n"
        "   │  ingest.py  (reads api_source_config, calls API)\n"
        "   ▼\n"
        "si3_raw_metrics.raw_payload    ← verbatim JSON, status = 'pending'\n"
        "   │\n"
        "   │  transform.py\n"
        "   ▼\n"
        "si3_monthly_metrics            ← normalized rows, status = 'transformed'\n"
        "   │\n"
        "   ▼\n"
        "v_si3_monthly_dashboard        ← unchanged; queries monthly_metrics as before")

    # ── 2. api_source_config Table ─────────────────────────────────────────
    add_heading(doc, "2. api_source_config Table", 1)
    add_body(doc,
        "A new table that stores everything needed to construct and authenticate "
        "an API call. API keys are never stored here — the api_key_env_var column "
        "holds only the name of the OS environment variable.")

    add_table(doc,
        ["Column", "Type", "Purpose"],
        [
            ["id",               "SERIAL PK",    "Auto-increment primary key"],
            ["source_id",        "INT FK",        "Links to existing si3_sources"],
            ["source_name",      "TEXT",          "Human-readable label (e.g. 'USGS Mineral Resources Monthly')"],
            ["base_url",         "TEXT",          "Protocol + host (e.g. https://minerals.usgs.gov)"],
            ["endpoint",         "TEXT",          "Path portion (e.g. /minerals/pubs/mcs/)"],
            ["http_method",      "TEXT CHECK",    "GET or POST"],
            ["auth_type",        "TEXT CHECK",    "none, api_key, or bearer"],
            ["api_key_env_var",  "TEXT",          "Name of env var holding the key – never the key itself"],
            ["default_params",   "JSONB",         "Static query params merged into every request"],
            ["response_schema",  "JSONB",         "Shape hint so the script knows where data rows live"],
            ["refresh_frequency","TEXT CHECK",    "daily / weekly / monthly / quarterly"],
            ["is_active",        "BOOLEAN",       "Soft-disable without deleting the row"],
            ["created_at",       "TIMESTAMPTZ",   "Row creation time (auto)"],
            ["updated_at",       "TIMESTAMPTZ",   "Last update time (auto via trigger)"],
        ]
    )

    # ── 3. si3_raw_metrics Migration ───────────────────────────────────────
    add_heading(doc, "3. si3_raw_metrics – Added Columns", 1)
    add_body(doc,
        "Three columns are appended to the existing table using an idempotent "
        "DO block so the migration is safe to re-run.")
    add_table(doc,
        ["New Column", "Type", "Purpose"],
        [
            ["raw_payload",      "JSONB",        "Verbatim JSON body returned by the external API"],
            ["api_source_id",    "INT FK",       "References api_source_config(id)"],
            ["ingested_at",      "TIMESTAMPTZ",  "Timestamp when the row was written"],
            ["ingestion_status", "TEXT CHECK",   "pending → transformed → error lifecycle flag"],
        ]
    )
    add_body(doc,
        "Indexes added: on ingestion_status (pending rows only), api_source_id, "
        "and ingested_at DESC for debugging recent runs.")

    # ── 4. ingest.py ────────────────────────────────────────────────────────
    add_heading(doc, "4. ingest.py – API Ingestion Script", 1)
    add_body(doc,
        "Reads all is_active = TRUE rows from api_source_config, constructs an HTTP "
        "request per source, stores the raw JSON response, and handles errors "
        "row-by-row so one failure does not abort the whole run.")

    add_heading(doc, "Key functions", 2)
    add_table(doc,
        ["Function", "Description"],
        [
            ["get_db_connection()",             "Builds psycopg2 connection from env vars (DB_HOST, DB_PORT, etc.)"],
            ["fetch_active_sources(conn, id?)", "SELECTs active rows from api_source_config"],
            ["build_headers(source)",           "Adds auth headers by reading the API key from the named env var at runtime"],
            ["call_api(source, extra_params)",  "Constructs URL, merges params, fires the request, returns parsed JSON"],
            ["insert_raw_payload(conn, …)",     "Writes raw JSON to si3_raw_metrics with status 'pending'"],
            ["mark_raw_error(conn, raw_id)",    "Flips status to 'error' on failure"],
            ["run_ingestion(source_id?, …)",    "Top-level loop: fetch sources → call API → store → handle errors"],
        ]
    )

    add_heading(doc, "CLI usage", 2)
    add_code(doc,
        "# Run all active sources\n"
        "python pipeline/ingest.py\n\n"
        "# Run a single source\n"
        "python pipeline/ingest.py --source-id 1\n\n"
        "# Pass year/month as API params\n"
        "python pipeline/ingest.py --year 2024 --month 3")

    add_heading(doc, "Required environment variables", 2)
    add_code(doc,
        "DB_HOST=localhost\n"
        "DB_PORT=5432\n"
        "DB_NAME=subindex_3\n"
        "DB_USER=<your_user>\n"
        "DB_PASSWORD=<your_password>\n"
        "# Plus any API key vars referenced in api_source_config.api_key_env_var\n"
        "# e.g. USGS_API_KEY=xxxx  (only needed if auth_type = 'api_key')")

    # ── 5. transform.py ─────────────────────────────────────────────────────
    add_heading(doc, "5. transform.py – Light Transformation Script", 1)
    add_body(doc,
        "Processes rows with ingestion_status = 'pending' from si3_raw_metrics "
        "and loads normalized records into si3_monthly_metrics. "
        "No time-aggregation is performed since USGS already provides monthly totals.")

    add_heading(doc, "Transformation steps", 2)
    add_table(doc,
        ["Step", "What it does"],
        [
            ["Field aliasing",    "FIELD_ALIASES dict maps USGS names (Commodity, Country, MetricType…) to internal standard names"],
            ["Validation",        "Checks all five required fields (country, mineral, metric, period, value) and that value is numeric"],
            ["ID mapping",        "Looks up country_id, mineral_id, metric_id from dimension tables using case-insensitive name match"],
            ["Date normalization","parse_period() accepts '2024-03', 'March 2024', '2024-03-01', '03/2024' → YYYY-MM-01"],
            ["Bulk insert",       "execute_batch into si3_monthly_metrics with ON CONFLICT DO NOTHING"],
            ["Status update",     "Sets ingestion_status = 'transformed' on success"],
        ]
    )

    add_heading(doc, "Key functions", 2)
    add_table(doc,
        ["Function", "Description"],
        [
            ["build_lookups(conn)",           "Loads {lowercase_name: id} maps for all three dimension tables in one pass"],
            ["normalize_record(raw)",         "Applies FIELD_ALIASES; returns a new dict with standard key names"],
            ["parse_period(period_str)",      "Multi-format date parser; always returns YYYY-MM-01"],
            ["validate_record(record)",       "Returns a list of error strings (empty = valid)"],
            ["extract_records(payload, …)",   "Navigates the JSON body using response_schema to find the data array"],
            ["transform_raw_row(conn, …)",    "Orchestrates the above steps for a single raw row"],
            ["insert_monthly_metrics(conn,…)","Bulk-inserts the transformed records"],
            ["run_transform(raw_id?)",        "Top-level loop over all pending rows"],
        ]
    )

    add_heading(doc, "CLI usage", 2)
    add_code(doc,
        "# Process all pending raw rows\n"
        "python pipeline/transform.py\n\n"
        "# Process a single raw row\n"
        "python pipeline/transform.py --raw-id 42")

    # ── 6. USGS End-to-End Example ─────────────────────────────────────────
    add_heading(doc, "6. USGS End-to-End Example", 1)

    add_heading(doc, "api_source_config seed row", 2)
    add_code(doc,
        "source_name      : USGS National Minerals Information Center\n"
        "base_url         : https://minerals.usgs.gov\n"
        "endpoint         : /minerals/pubs/mcs/\n"
        "http_method      : GET\n"
        "auth_type        : none\n"
        "api_key_env_var  : NULL\n"
        "default_params   : {\"format\": \"json\"}\n"
        "response_schema  : {\"type\": \"json_object\", \"data_key\": \"MineralResources\"}\n"
        "refresh_frequency: monthly\n"
        "is_active        : true")

    add_heading(doc, "HTTP request constructed at runtime", 2)
    add_code(doc,
        "GET https://minerals.usgs.gov/minerals/pubs/mcs/?format=json&year=2024&month=3")

    add_heading(doc, "Sample raw_payload written to si3_raw_metrics", 2)
    add_code(doc,
        "{\n"
        "  \"MineralResources\": [\n"
        "    {\n"
        "      \"Country\":    \"United States\",\n"
        "      \"Commodity\":  \"Copper\",\n"
        "      \"MetricType\": \"production\",\n"
        "      \"Period\":     \"2024-03\",\n"
        "      \"Value\":      85000,\n"
        "      \"Unit\":       \"metric tons\"\n"
        "    },\n"
        "    {\n"
        "      \"Country\":    \"Chile\",\n"
        "      \"Commodity\":  \"Copper\",\n"
        "      \"MetricType\": \"production\",\n"
        "      \"Period\":     \"2024-03\",\n"
        "      \"Value\":      420000,\n"
        "      \"Unit\":       \"metric tons\"\n"
        "    }\n"
        "  ]\n"
        "}")

    add_heading(doc, "Records inserted into si3_monthly_metrics", 2)
    add_table(doc,
        ["country_id", "mineral_id", "metric_id", "period", "value", "unit"],
        [
            ["5 (United States)", "12 (Copper)", "3 (production)", "2024-03-01", "85000.0",  "metric tons"],
            ["9 (Chile)",         "12 (Copper)", "3 (production)", "2024-03-01", "420000.0", "metric tons"],
        ]
    )
    add_body(doc,
        "IDs shown above are illustrative. Actual values depend on the content of "
        "si3_countries, si3_mineral_codes, and si3_metric_definitions.")

    # ── 7. Running the Full Pipeline ───────────────────────────────────────
    add_heading(doc, "7. Running the Full Pipeline", 1)
    add_code(doc,
        "# 1. Apply schema changes (run once)\n"
        "psql -d subindex_3 -f schema/api_pipeline.sql\n\n"
        "# 2. Set credentials\n"
        "export DB_HOST=localhost DB_PORT=5432 DB_NAME=subindex_3 \\\n"
        "       DB_USER=... DB_PASSWORD=...\n\n"
        "# 3. Ingest this month's data\n"
        "python pipeline/ingest.py --year 2024 --month 3\n\n"
        "# 4. Transform pending raw rows\n"
        "python pipeline/transform.py")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

doc = Document()

# Set default body font
style = doc.styles["Normal"]
style.font.name = "Calibri"
style.font.size = Pt(11)

build(doc)
doc.save(OUT_PATH)
print(f"Saved: {OUT_PATH}")
