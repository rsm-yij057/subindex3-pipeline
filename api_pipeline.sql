-- =============================================================================
--  SI3 — Critical Mineral Endowment
--  Database: subindex_3
--  Schema:   public
--
--  Design notes:
--    • Naming aligned with SI1 (si3_<purpose>, v_si3_<purpose>, *_id_seq)
--    • SERIAL primary keys (matches SI1's *_id_seq pattern)
--    • Two-stage architecture preserved from SI3 prototype:
--        API → si3_raw_metrics (verbatim JSONB)
--             → si3_annual_metrics  (USGS-derived, yearly)
--             → si3_monthly_metrics (Comtrade-derived, monthly)
--    • Operational tables added per SI1 pattern:
--        si3_collection_runs, si3_collection_log, si3_data_gaps
--    • Idempotent: every CREATE uses IF NOT EXISTS; every ALTER wrapped in DO blocks.
--      Safe to re-run without dropping data.
--
--  Apply with:
--    psql -d subindex_3 -f schema/api_pipeline.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. EXTENSIONS & SHARED HELPERS
-- -----------------------------------------------------------------------------

-- For citext columns (case-insensitive country/mineral name matching during transform)
CREATE EXTENSION IF NOT EXISTS citext;

-- Trigger function: set updated_at on every UPDATE.
-- Defined once, reused by every table that has updated_at.
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 1. DIMENSION TABLES
--    Reference data the rest of the schema joins to.
--    Seeded with the 6 SI3 target countries / minerals / metrics at the bottom
--    so the database is usable immediately after this script runs.
-- =============================================================================

-- 1.1 Countries -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS si3_countries (
    id              SERIAL      PRIMARY KEY,
    country_name    CITEXT      NOT NULL UNIQUE,
    iso3            CHAR(3)     NOT NULL UNIQUE,
    m49_code        CHAR(3)     NOT NULL UNIQUE,            -- UN M49 numeric (Comtrade reporterCode)
    usgs_aliases    TEXT[]      NOT NULL DEFAULT '{}',      -- alternate spellings used by USGS
    is_target       BOOLEAN     NOT NULL DEFAULT TRUE,      -- one of the 6 SI3 countries?
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_si3_countries_iso3   ON si3_countries(iso3);
CREATE INDEX IF NOT EXISTS idx_si3_countries_target ON si3_countries(is_target) WHERE is_target;

DROP TRIGGER IF EXISTS trg_si3_countries_updated ON si3_countries;
CREATE TRIGGER trg_si3_countries_updated
    BEFORE UPDATE ON si3_countries
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- 1.2 Minerals ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS si3_minerals (
    id              SERIAL      PRIMARY KEY,
    mineral_name    CITEXT      NOT NULL UNIQUE,
    usgs_slug       TEXT        NOT NULL UNIQUE,            -- e.g. 'rare-earths' (URL slug)
    hs_codes_raw    TEXT[]      NOT NULL DEFAULT '{}',      -- HS6 codes for ore/concentrate stage
    hs_codes_processed TEXT[]   NOT NULL DEFAULT '{}',      -- HS6 codes for refined stage
    weight          NUMERIC(5,4) NOT NULL DEFAULT 0,        -- mineral importance weight (sums to 1.0)
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (weight >= 0 AND weight <= 1)
);

DROP TRIGGER IF EXISTS trg_si3_minerals_updated ON si3_minerals;
CREATE TRIGGER trg_si3_minerals_updated
    BEFORE UPDATE ON si3_minerals
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- 1.3 Metric definitions --------------------------------------------------------
-- The five SI3 metrics + room to add diagnostic overlays later.
CREATE TABLE IF NOT EXISTS si3_metric_definitions (
    id              SERIAL      PRIMARY KEY,
    metric_code     TEXT        NOT NULL UNIQUE,            -- snake_case key, e.g. 'production_share'
    metric_name     TEXT        NOT NULL,                   -- human label
    description     TEXT,
    unit            TEXT        NOT NULL,                   -- 'ratio', 'percent', 'usd', 'metric_tons'
    granularity     TEXT        NOT NULL,                   -- 'annual' | 'monthly' | 'one_off'
    source          TEXT        NOT NULL,                   -- 'usgs' | 'comtrade'
    weight          NUMERIC(5,4) NOT NULL DEFAULT 0,        -- composite weight in SI3 score
    is_diagnostic   BOOLEAN     NOT NULL DEFAULT FALSE,     -- TRUE = overlay only, not in base composite
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (granularity IN ('annual','monthly','one_off')),
    CHECK (source      IN ('usgs','comtrade')),
    CHECK (weight >= 0 AND weight <= 1)
);

DROP TRIGGER IF EXISTS trg_si3_metric_definitions_updated ON si3_metric_definitions;
CREATE TRIGGER trg_si3_metric_definitions_updated
    BEFORE UPDATE ON si3_metric_definitions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- 2. API SOURCE CONFIG
--    Configuration-driven ingestion: add a new data source by inserting a row
--    here, no code change required. API keys live in env vars referenced by
--    api_key_env_var (the key itself is NEVER stored in the database).
-- =============================================================================

CREATE TABLE IF NOT EXISTS si3_api_source_config (
    id                  SERIAL      PRIMARY KEY,
    source_name         TEXT        NOT NULL UNIQUE,        -- e.g. 'USGS Mineral Commodity Summaries'
    base_url            TEXT        NOT NULL,               -- protocol + host
    endpoint            TEXT        NOT NULL,               -- path portion
    http_method         TEXT        NOT NULL DEFAULT 'GET',
    auth_type           TEXT        NOT NULL DEFAULT 'none',
    api_key_env_var     TEXT,                               -- name of env var holding the key
    default_params      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    response_schema     JSONB       NOT NULL DEFAULT '{}'::jsonb,  -- hint where data rows live in JSON
    refresh_frequency   TEXT        NOT NULL DEFAULT 'monthly',
    rate_limit_seconds  NUMERIC(5,2) NOT NULL DEFAULT 0.6,  -- polite delay between calls
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (http_method       IN ('GET','POST')),
    CHECK (auth_type         IN ('none','api_key','bearer')),
    CHECK (refresh_frequency IN ('daily','weekly','monthly','quarterly','annual'))
);

CREATE INDEX IF NOT EXISTS idx_si3_api_source_config_active ON si3_api_source_config(is_active) WHERE is_active;

DROP TRIGGER IF EXISTS trg_si3_api_source_config_updated ON si3_api_source_config;
CREATE TRIGGER trg_si3_api_source_config_updated
    BEFORE UPDATE ON si3_api_source_config
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- 3. OPERATIONAL TABLES (SI1-aligned)
--    These tables track WHEN ingestion ran, WHAT it tried to do, and WHERE
--    data is missing. They are append-only logs (no UPDATE except for status
--    transitions on collection_runs).
-- =============================================================================

-- 3.1 collection_runs — one row per pipeline invocation -------------------------
CREATE TABLE IF NOT EXISTS si3_collection_runs (
    id              SERIAL      PRIMARY KEY,
    run_uuid        UUID        NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    pipeline_name   TEXT        NOT NULL,                   -- 'usgs_ingest', 'comtrade_ingest', 'transform'
    api_source_id   INT         REFERENCES si3_api_source_config(id) ON DELETE SET NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at     TIMESTAMPTZ,
    status          TEXT        NOT NULL DEFAULT 'running',
    rows_attempted  INT         NOT NULL DEFAULT 0,
    rows_succeeded  INT         NOT NULL DEFAULT 0,
    rows_failed     INT         NOT NULL DEFAULT 0,
    triggered_by    TEXT,                                   -- 'cron', 'manual', user/CI id
    notes           TEXT,
    CHECK (status IN ('running','success','partial','failed','cancelled'))
);

CREATE INDEX IF NOT EXISTS idx_si3_collection_runs_pipeline ON si3_collection_runs(pipeline_name);
CREATE INDEX IF NOT EXISTS idx_si3_collection_runs_started  ON si3_collection_runs(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_si3_collection_runs_status   ON si3_collection_runs(status);


-- 3.2 collection_log — one row per (country, mineral, period) attempt -----------
CREATE TABLE IF NOT EXISTS si3_collection_log (
    id              SERIAL      PRIMARY KEY,
    run_id          INT         NOT NULL REFERENCES si3_collection_runs(id) ON DELETE CASCADE,
    country_id      INT         REFERENCES si3_countries(id) ON DELETE SET NULL,
    mineral_id      INT         REFERENCES si3_minerals(id)  ON DELETE SET NULL,
    metric_id       INT         REFERENCES si3_metric_definitions(id) ON DELETE SET NULL,
    period_start    DATE,                                   -- e.g. '2024-03-01' for monthly, '2024-01-01' for annual
    period_end      DATE,
    status          TEXT        NOT NULL,                   -- 'success' | 'no_data' | 'http_error' | 'parse_error'
    http_status     INT,
    error_message   TEXT,
    raw_metric_id   INT,                                    -- FK to si3_raw_metrics(id) — set after insert
    duration_ms     INT,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (status IN ('success','no_data','http_error','parse_error','rate_limited','skipped'))
);

CREATE INDEX IF NOT EXISTS idx_si3_collection_log_run    ON si3_collection_log(run_id);
CREATE INDEX IF NOT EXISTS idx_si3_collection_log_status ON si3_collection_log(status);
CREATE INDEX IF NOT EXISTS idx_si3_collection_log_period ON si3_collection_log(period_start);


-- 3.3 data_gaps — known missing (country × mineral × metric × period) cells -----
-- Populated by the gap-detection job; consumed by dashboards and re-fetch logic.
CREATE TABLE IF NOT EXISTS si3_data_gaps (
    id              SERIAL      PRIMARY KEY,
    country_id      INT         NOT NULL REFERENCES si3_countries(id) ON DELETE CASCADE,
    mineral_id      INT         NOT NULL REFERENCES si3_minerals(id)  ON DELETE CASCADE,
    metric_id       INT         NOT NULL REFERENCES si3_metric_definitions(id) ON DELETE CASCADE,
    period_start    DATE        NOT NULL,
    gap_type        TEXT        NOT NULL,                   -- 'missing' | 'withheld' | 'estimated' | 'inconsistent'
    severity        TEXT        NOT NULL DEFAULT 'medium',  -- 'low' | 'medium' | 'high'
    detected_in_run INT         REFERENCES si3_collection_runs(id) ON DELETE SET NULL,
    notes           TEXT,
    is_resolved     BOOLEAN     NOT NULL DEFAULT FALSE,
    resolved_at     TIMESTAMPTZ,
    detected_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (gap_type IN ('missing','withheld','estimated','inconsistent')),
    CHECK (severity IN ('low','medium','high')),
    UNIQUE (country_id, mineral_id, metric_id, period_start, gap_type)
);

CREATE INDEX IF NOT EXISTS idx_si3_data_gaps_unresolved ON si3_data_gaps(is_resolved) WHERE NOT is_resolved;
CREATE INDEX IF NOT EXISTS idx_si3_data_gaps_period     ON si3_data_gaps(period_start);


-- =============================================================================
-- 4. RAW METRICS (verbatim from APIs)
--    Mixed granularity by design: USGS rows have annual periods, Comtrade rows
--    have monthly periods. The granularity column makes it explicit.
--    raw_payload preserves the original API response so transforms are repeatable.
-- =============================================================================

CREATE TABLE IF NOT EXISTS si3_raw_metrics (
    id                  SERIAL      PRIMARY KEY,
    api_source_id       INT         REFERENCES si3_api_source_config(id) ON DELETE SET NULL,
    run_id              INT         REFERENCES si3_collection_runs(id)   ON DELETE SET NULL,

    -- Origin coordinates (nullable: filled by transform if not by ingest)
    country_id          INT         REFERENCES si3_countries(id),
    mineral_id          INT         REFERENCES si3_minerals(id),
    metric_id           INT         REFERENCES si3_metric_definitions(id),

    -- Period (always the FIRST DAY of the period, regardless of granularity)
    period_start        DATE        NOT NULL,
    granularity         TEXT        NOT NULL,               -- 'annual' | 'monthly'

    -- Raw values (populated by ingest where available; transform may also fill)
    raw_value           NUMERIC,
    raw_unit            TEXT,
    raw_flag            TEXT,                               -- 'W' (withheld), 'EST', 'NEG', etc.
    raw_payload         JSONB       NOT NULL,               -- full JSON record from API

    -- Lifecycle
    ingestion_status    TEXT        NOT NULL DEFAULT 'pending',  -- pending → transformed → error
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    transformed_at      TIMESTAMPTZ,
    error_message       TEXT,

    CHECK (granularity      IN ('annual','monthly')),
    CHECK (ingestion_status IN ('pending','transformed','error','skipped'))
);

-- Most-used filter is "find pending rows for transform"
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_pending  ON si3_raw_metrics(ingestion_status) WHERE ingestion_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_run      ON si3_raw_metrics(run_id);
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_source   ON si3_raw_metrics(api_source_id);
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_period   ON si3_raw_metrics(period_start);
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_ingested ON si3_raw_metrics(ingested_at DESC);

-- Composite index for the typical "get all data for this cell" query
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_cmm
    ON si3_raw_metrics(country_id, mineral_id, metric_id, period_start);


-- =============================================================================
-- 5. NORMALIZED METRICS (transformed; one cell per row)
--    Split by granularity so each table has clean semantics and no NULL period
--    components. Both refer to the same dimensions.
-- =============================================================================

-- 5.1 Annual normalized metrics (USGS + any annually-aggregated Comtrade) -------
CREATE TABLE IF NOT EXISTS si3_annual_metrics (
    id              SERIAL      PRIMARY KEY,
    country_id      INT         NOT NULL REFERENCES si3_countries(id),
    mineral_id      INT         NOT NULL REFERENCES si3_minerals(id),
    metric_id       INT         NOT NULL REFERENCES si3_metric_definitions(id),
    year            INT         NOT NULL,
    value           NUMERIC,
    unit            TEXT,
    flag            TEXT,                                   -- carry forward 'W', 'EST', etc.
    raw_metric_id   INT         REFERENCES si3_raw_metrics(id) ON DELETE SET NULL,
    transformed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (country_id, mineral_id, metric_id, year),
    CHECK (year BETWEEN 1900 AND 2100)
);

CREATE INDEX IF NOT EXISTS idx_si3_annual_metrics_year ON si3_annual_metrics(year);


-- 5.2 Monthly normalized metrics (Comtrade) -------------------------------------
CREATE TABLE IF NOT EXISTS si3_monthly_metrics (
    id              SERIAL      PRIMARY KEY,
    country_id      INT         NOT NULL REFERENCES si3_countries(id),
    mineral_id      INT         NOT NULL REFERENCES si3_minerals(id),
    metric_id       INT         NOT NULL REFERENCES si3_metric_definitions(id),
    period          DATE        NOT NULL,                   -- always the 1st of the month
    value           NUMERIC,
    unit            TEXT,
    flag            TEXT,
    raw_metric_id   INT         REFERENCES si3_raw_metrics(id) ON DELETE SET NULL,
    transformed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (country_id, mineral_id, metric_id, period),
    CHECK (EXTRACT(DAY FROM period) = 1)                    -- enforce 1st-of-month convention
);

CREATE INDEX IF NOT EXISTS idx_si3_monthly_metrics_period ON si3_monthly_metrics(period);


-- =============================================================================
-- 6. VIEWS (SI1-aligned: v_si3_*)
-- =============================================================================

-- 6.1 v_si3_completeness — % of expected cells filled, by country × metric -----
CREATE OR REPLACE VIEW v_si3_completeness AS
WITH expected_cells AS (
    -- Cartesian product: target countries × active minerals × active metrics
    SELECT
        c.id   AS country_id,    c.country_name,
        mn.id  AS mineral_id,    mn.mineral_name,
        md.id  AS metric_id,     md.metric_code,    md.granularity
    FROM si3_countries c
    CROSS JOIN si3_minerals mn
    CROSS JOIN si3_metric_definitions md
    WHERE c.is_target  = TRUE
      AND mn.is_active = TRUE
      AND md.is_active = TRUE
),
filled AS (
    SELECT country_id, mineral_id, metric_id, COUNT(*)::int AS n_filled
    FROM si3_annual_metrics
    WHERE value IS NOT NULL
    GROUP BY 1,2,3
    UNION ALL
    SELECT country_id, mineral_id, metric_id, COUNT(*)::int AS n_filled
    FROM si3_monthly_metrics
    WHERE value IS NOT NULL
    GROUP BY 1,2,3
)
SELECT
    e.country_name,
    e.mineral_name,
    e.metric_code,
    e.granularity,
    COALESCE(SUM(f.n_filled), 0)::int                   AS n_filled,
    CASE WHEN COALESCE(SUM(f.n_filled), 0) > 0 THEN 1 ELSE 0 END AS has_any_data
FROM expected_cells e
LEFT JOIN filled f USING (country_id, mineral_id, metric_id)
GROUP BY e.country_name, e.mineral_name, e.metric_code, e.granularity
ORDER BY e.country_name, e.mineral_name, e.metric_code;


-- 6.2 v_si3_latest — most recent value per (country, mineral, metric) ----------
CREATE OR REPLACE VIEW v_si3_latest AS
WITH all_normalized AS (
    SELECT country_id, mineral_id, metric_id,
           make_date(year, 1, 1) AS period,
           value, unit, flag,
           'annual'::text AS granularity
    FROM si3_annual_metrics
    UNION ALL
    SELECT country_id, mineral_id, metric_id,
           period,
           value, unit, flag,
           'monthly'::text AS granularity
    FROM si3_monthly_metrics
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY country_id, mineral_id, metric_id
               ORDER BY period DESC
           ) AS rn
    FROM all_normalized
    WHERE value IS NOT NULL
)
SELECT
    c.country_name,
    mn.mineral_name,
    md.metric_code,
    r.granularity,
    r.period            AS latest_period,
    r.value,
    r.unit,
    r.flag
FROM ranked r
JOIN si3_countries          c  ON c.id  = r.country_id
JOIN si3_minerals           mn ON mn.id = r.mineral_id
JOIN si3_metric_definitions md ON md.id = r.metric_id
WHERE r.rn = 1
ORDER BY c.country_name, mn.mineral_name, md.metric_code;


-- 6.3 v_si3_recent_runs — last 30 days of pipeline activity --------------------
CREATE OR REPLACE VIEW v_si3_recent_runs AS
SELECT
    r.id              AS run_id,
    r.pipeline_name,
    s.source_name,
    r.started_at,
    r.finished_at,
    r.finished_at - r.started_at      AS duration,
    r.status,
    r.rows_attempted,
    r.rows_succeeded,
    r.rows_failed,
    CASE WHEN r.rows_attempted > 0
         THEN ROUND(100.0 * r.rows_succeeded / r.rows_attempted, 1)
         ELSE NULL
    END                               AS pct_succeeded,
    r.triggered_by,
    r.notes
FROM si3_collection_runs r
LEFT JOIN si3_api_source_config s ON s.id = r.api_source_id
WHERE r.started_at >= NOW() - INTERVAL '30 days'
ORDER BY r.started_at DESC;


-- =============================================================================
-- 7. SEED DATA
--    The 6 SI3 target countries, 6 minerals (with HS codes + weights),
--    and 5 SI3 metrics. Idempotent via ON CONFLICT.
-- =============================================================================

-- 7.1 Countries -----------------------------------------------------------------
INSERT INTO si3_countries (country_name, iso3, m49_code, usgs_aliases) VALUES
    ('USA',         'USA', '842', ARRAY['United States','United States of America','U.S.']),
    ('UAE',         'ARE', '784', ARRAY['United Arab Emirates']),
    ('Brazil',      'BRA', '076', ARRAY['Brazil']),
    ('India',       'IND', '356', ARRAY['India']),
    ('Singapore',   'SGP', '702', ARRAY['Singapore']),
    ('Philippines', 'PHL', '608', ARRAY['Philippines'])
ON CONFLICT (country_name) DO NOTHING;


-- 7.2 Minerals ------------------------------------------------------------------
-- HS codes carried over from the SI3 prototype (HS_CODES dict in the notebook).
-- weight = preliminary equal weighting (1/6 ≈ 0.1667); adjust per mineral
-- importance ranking when the methodology team finalizes it.
INSERT INTO si3_minerals (mineral_name, usgs_slug, hs_codes_raw, hs_codes_processed, weight) VALUES
    ('Copper',      'copper',
        ARRAY['260300'],
        ARRAY['740311','740319','740321','740322','740329'],
        0.1667),
    ('Lithium',     'lithium',
        ARRAY['253090'],
        ARRAY['282520','283691'],
        0.1667),
    ('Nickel',      'nickel',
        ARRAY['260400'],
        ARRAY['750110','750120','750210','750220'],
        0.1667),
    ('Cobalt',      'cobalt',
        ARRAY['260500'],
        ARRAY['810520','810530'],
        0.1667),
    ('Rare Earths', 'rare-earths',
        ARRAY['253090'],
        ARRAY['284610','284690'],
        0.1667),
    ('Silicon',     'silicon',
        ARRAY['262100'],
        ARRAY['280461','280469'],
        0.1665)
ON CONFLICT (mineral_name) DO NOTHING;


-- 7.3 Metric definitions --------------------------------------------------------
-- Composite weights (sum to 1.0): production 0.40, reserves 0.30, refining 0.30
-- Value-add ratio and YoY growth are diagnostic overlays (weight 0).
INSERT INTO si3_metric_definitions
    (metric_code, metric_name, description, unit, granularity, source, weight, is_diagnostic) VALUES
    ('production_share', 'Production Share',
        'Country production / world total production (latest year)',
        'ratio', 'annual',  'usgs',     0.40, FALSE),
    ('reserves_share',   'Reserves Share',
        'Country reserves / world total reserves (latest year)',
        'ratio', 'annual',  'usgs',     0.30, FALSE),
    ('refining_share',   'Refining Capacity Share',
        'Country processed exports / world processed exports (latest full year)',
        'ratio', 'monthly', 'comtrade', 0.30, FALSE),
    ('yoy_growth',       'YoY Production Growth',
        'Latest-vs-prior year change in production volume',
        'ratio', 'annual',  'usgs',     0.00, TRUE),
    ('value_add_ratio',  'Value-Add Ratio',
        'processed_exports / (raw_exports + processed_exports), latest full year',
        'ratio', 'monthly', 'comtrade', 0.00, TRUE)
ON CONFLICT (metric_code) DO NOTHING;


-- 7.4 API source config — the two SI3 data sources -----------------------------
INSERT INTO si3_api_source_config
    (source_name, base_url, endpoint, http_method, auth_type, api_key_env_var,
     default_params, response_schema, refresh_frequency, rate_limit_seconds) VALUES
    ('USGS Mineral Commodity Summaries (ScienceBase)',
        'https://www.sciencebase.gov',
        '/catalog/items',
        'GET', 'none', NULL,
        '{"format":"json","max":200}'::jsonb,
        '{"discovery":"by_search","title_pattern":"Mineral Commodity Summaries {year} Data Release"}'::jsonb,
        'annual', 0.4),
    ('UN Comtrade Plus',
        'https://comtradeapi.un.org',
        '/data/v1/get',
        'GET', 'api_key', 'COMTRADE_KEY',
        '{"typeCode":"C","freqCode":"M","clCode":"HS","flowCode":"X","partnerCode":"0"}'::jsonb,
        '{"data_key":"data"}'::jsonb,
        'monthly', 0.6)
ON CONFLICT (source_name) DO NOTHING;


COMMIT;

-- =============================================================================
-- POST-INSTALL SANITY CHECKS
-- Run these manually to verify the schema applied correctly.
-- =============================================================================
--
-- \dt si3_*
-- \dv v_si3_*
-- SELECT COUNT(*) FROM si3_countries;            -- expect 6
-- SELECT COUNT(*) FROM si3_minerals;             -- expect 6
-- SELECT COUNT(*) FROM si3_metric_definitions;   -- expect 5
-- SELECT COUNT(*) FROM si3_api_source_config;    -- expect 2
-- SELECT * FROM v_si3_completeness LIMIT 5;      -- works on empty data: all 0s
-- SELECT * FROM v_si3_latest;                    -- empty until ingest runs
-- SELECT * FROM v_si3_recent_runs;               -- empty until ingest runs
