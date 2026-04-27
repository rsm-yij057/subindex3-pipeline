# Manual Facility Entry — Template README

## What this is

The CSV template (`ws2_si1_facility_template.csv`) is the bridge between
unstructured sources (news articles, press releases, PDF reports) and the WS2 SI1
database. Per the project's design Q6, ~60% of facility data will be entered this way.

Each row = one data center facility. The validator (`validate_facility_csv.py`) checks
your file before it touches the database.

## Workflow

1. Copy `ws2_si1_facility_template.csv` to a new file, e.g. `usa_2026q1.csv`.
2. Delete the example row.
3. Add one row per facility you have evidence for.
4. Run `python validate_facility_csv.py usa_2026q1.csv`.
5. Fix any reported errors and re-run until clean.
6. Run `python validate_facility_csv.py usa_2026q1.csv --load --db postgres://...` to load.

## Columns

### Required (the row will be rejected without these)

| Column | Format | Notes |
|---|---|---|
| `country` | One of: USA, UAE, Brazil, India, Singapore, Philippines | Must match exactly (case-insensitive matched, but use the canonical form) |
| `facility_name` | Free text, ≤200 chars | Use the operator's own naming when known. If the source uses a project codename ("Stargate II"), keep it. |
| `operator` | Free text | The owner/operator. AWS, Microsoft, Google, Meta, Equinix, NTT, STT, G42, Khazna, etc. Empty string if truly unknown — don't write "Unknown". |
| `capacity_mw` | Number, e.g. `120.0` | Critical IT MW preferred. If gross MW only, set `capacity_basis = gross` and note in `notes`. |
| `status` | One of: operational, under_construction, permitted, announced, cancelled, decommissioned | Default headline scoring only counts `operational` (installed) and `under_construction` + `permitted` (pipeline). |
| `primary_source` | Free text | Cite the source clearly. Examples: `DC Byte 2026Q1 export`, `SEC 10-K AMZN FY2025`, `DCD article 2026-03-15`, `Khazna press release 2025-09-12`. |
| `source_collected_date` | YYYY-MM-DD | The date YOU pulled this datum (today, usually). |

### Recommended (improve data quality, no hard rejection)

| Column | Format | Notes |
|---|---|---|
| `city` | Free text | Helps disambiguate when one operator has multiple facilities in one country. |
| `region` | Free text | State (USA), Emirate (UAE), state (India), etc. |
| `capacity_basis` | One of: `critical_it`, `gross`, `unknown` | Default `critical_it`. |
| `date_announced` | YYYY-MM-DD | When the project was first publicly announced. |
| `date_operational` | YYYY-MM-DD | When facility went live. Required if `status = operational`. |
| `expected_operational` | YYYY-MM-DD | For non-operational, estimated commissioning date. |
| `source_url` | URL | Direct link to the citation. |
| `source_published_date` | YYYY-MM-DD | When the SOURCE was published (vs. when YOU collected). |
| `confidence` | One of: `high`, `medium`, `low` | Default `medium`. Use `high` only when capacity_mw and status are explicitly stated by a primary source (operator press release, regulatory filing, DC Byte). Use `low` for back-of-envelope estimates. |

### Optional (for SI3 / cross-workstream use)

| Column | Format | Notes |
|---|---|---|
| `investment_value_usd` | Number, USD | If reported in foreign currency, convert and fill `investment_currency`, `investment_fx_rate`, `investment_fx_date`. |
| `investment_currency` | ISO 4217 (e.g. USD, AED, BRL) | Default USD if not specified. |
| `investment_fx_rate` | Number | Rate used to convert to USD. |
| `investment_fx_date` | YYYY-MM-DD | Date of FX rate. Use IMF quarter-end rate. |
| `energy_source` | One of: `renewable`, `grid`, `natural_gas`, `mixed`, blank | |
| `chip_type_if_known` | Free text | "H100", "B200", "MI300", "TPU v5", etc. |
| `notes` | Free text | Any caveats: gross-MW conversion factor, conflicting sources, etc. |

## Hard rules

1. **No empty rows in the middle of the file.** First blank row = end of data.
2. **No tab characters in any cell.** Save as comma-delimited UTF-8.
3. **Dates must be `YYYY-MM-DD`** (no `01/15/2026` or `15-Jan-2026`).
4. **Numbers must use `.` as decimal separator**, no thousands separator (`120.5` not `120,5` not `1,200`).
5. **`capacity_mw > 0`** if provided (zero or negative is a validation error).
6. **`date_operational >= date_announced`** if both are provided.
7. **`status = operational` requires either `date_operational` or a high-confidence note.**

## Common mistakes to avoid

- Writing "TBD" or "Q3 2026" in a date field — leave it blank instead and put the qualitative timing in `notes`.
- Mixing gross MW and critical IT MW without flagging — always set `capacity_basis` accurately.
- Citing "industry estimate" without a URL — the methodology paper requires every datum to be traceable.
- Using `announced` for projects that have actually broken ground — those are `under_construction`.
- Forgetting that `cancelled` facilities don't appear in `v_facility_latest` and don't contribute to the score (they're kept for historical audit only).
